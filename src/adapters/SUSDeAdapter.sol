// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYLiquidAdapter} from "../interfaces/IYLiquidAdapter.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IYLiquidAdapterUI, IYLiquidMarketPositionReader} from "../interfaces/IYLiquidAdapterUI.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";
import {AdapterProxy} from "./AdapterProxy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}


contract SUSDeAdapter is IYLiquidAdapter, IYLiquidAdapterUI {
    using SafeERC20 for *;

    uint8 public constant CALLBACK_PHASE_OPEN_USDC = 1;
    uint8 public constant CALLBACK_PHASE_SETTLE_USDE = 2;
    uint8 public constant CALLBACK_PHASE_FORCE_CLOSE_USDE = 3;

    enum Status {
        None,
        Open,
        Closed
    }

    struct CooldownPosition {
        AdapterProxy proxy;
        address receiver;
        uint128 principal;
        uint128 susdeLocked;
        uint128 usdeExpected;
        uint64 cooldownEnd;
        Status status;
    }

    uint256 public constant WAD = 1e18;

    address public immutable market;
    IERC20 public immutable loanAsset;
    IERC20 public immutable usde;
    IsUSDe public immutable sUSDe;

    uint256 public immutable USDE_PRECISION;

    /// @notice The min rate of USDe to loan asset
    uint256 public minRateWad;

    mapping(uint256 => CooldownPosition) public positions;

    uint256 private _lock;

    error NotMarket();
    error ZeroReceiver();
    error ZeroAmount();
    error CooldownBusy();
    error UnknownPosition();
    error CooldownIncomplete();
    error RepayShortfall();
    error MinRateNotMet();

    event PositionOpened(
        uint256 indexed tokenId,
        address indexed receiver,
        uint256 principal,
        uint256 susdeLocked,
        uint256 usdeExpected,
        uint256 cooldownEnd
    );
    event PositionSettled(
        uint256 indexed tokenId, address indexed receiver, uint256 usdeReceived, uint256 usdcRepaid, uint256 cooldownEnd
    );
    event PositionForceClosed(
        uint256 indexed tokenId, address indexed receiver, uint256 usdeReceived, uint256 usdcRecovered, uint256 cooldownEnd
    );

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    modifier nonReentrant() {
        require(_lock == 0, "reentrant");
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor(address _market, address _loanAsset, address _sUSDe, uint256 _minRateWad) {
        require(_market != address(0), "zero market");
        require(_loanAsset != address(0), "zero loan asset");
        require(_sUSDe != address(0), "zero susde");

        market = _market;
        loanAsset = IERC20(_loanAsset);
        sUSDe = IsUSDe(_sUSDe);
        usde = IERC20(sUSDe.asset());

        require(_minRateWad > 1e18, "min rate too low");
        minRateWad = _minRateWad;

        USDE_PRECISION = 10 ** uint256(IERC20Metadata(_sUSDe).decimals() - IERC20Metadata(_loanAsset).decimals());
    }

    function setMinRate(uint256 _minRateWad) external {
        require(msg.sender == ITokenizedStrategy(market).management(), "not management");
        require(_minRateWad > 1e18, "min rate too low");
        minRateWad = _minRateWad;
    }

    function executeOpen(
        uint256 tokenId,
        address owner,
        address,
        uint256 amount,
        address receiver,
        uint256 collateralAmount,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint64 expectedDurationSeconds)
    {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();
        if (collateralAmount == 0) revert ZeroAmount();

        uint256 usdeExpected = sUSDe.previewRedeem(collateralAmount);
        if (usdeExpected < amount * USDE_PRECISION * minRateWad / WAD) revert MinRateNotMet();

        loanAsset.safeTransfer(receiver, amount);
        IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_OPEN_USDC, owner, address(loanAsset), amount, callbackData
        );

        AdapterProxy proxy = new AdapterProxy(address(this));

        sUSDe.safeTransferFrom(receiver, address(proxy), collateralAmount);

        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);

        calls[0] = AdapterProxy.Call({
            target: address(sUSDe),
            value: 0,
            data: abi.encodeCall(IsUSDe.cooldownShares, collateralAmount)
        });

        proxy.execute(calls);

        expectedDurationSeconds = sUSDe.cooldownDuration();
        uint64 cooldownEnd = uint64(block.timestamp + expectedDurationSeconds);
        positions[tokenId] = CooldownPosition({
            proxy: proxy,
            receiver: receiver,
            principal: uint128(amount),
            susdeLocked: uint128(collateralAmount),
            usdeExpected: uint128(usdeExpected),
            cooldownEnd: cooldownEnd,
            status: Status.Open
        });

        emit PositionOpened(tokenId, receiver, amount, collateralAmount, usdeExpected, cooldownEnd);
        _emitStandardizedOpen(tokenId, owner, receiver, amount, collateralAmount, usdeExpected, cooldownEnd);
    }

    function executeSettle(
        uint256 tokenId,
        address owner,
        address,
        uint256 amountOwed,
        address receiver,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRepaid)
    {
        CooldownPosition memory position = positions[tokenId];
        if (position.status != Status.Open) revert UnknownPosition();
        address settleReceiver = receiver == address(0) ? position.receiver : receiver;

        uint256 usdeReceived = _unstakeUSDe(position.proxy);

        usde.safeTransfer(settleReceiver, usdeReceived);
        IYLiquidAdapterCallbackReceiver(settleReceiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_SETTLE_USDE, owner, address(usde), usdeReceived, callbackData
        );

        loanAsset.safeTransferFrom(settleReceiver, market, amountOwed);

        _closePosition(tokenId);
        amountRepaid = amountOwed;
        emit PositionSettled(tokenId, settleReceiver, usdeReceived, amountRepaid, position.cooldownEnd);
        _emitStandardizedClose(tokenId, owner, settleReceiver, CloseType.Settle, usdeReceived, amountRepaid);
    }

    function executeForceClose(
        uint256 tokenId,
        address owner,
        address,
        uint256 amountOwed,
        address receiver,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRecovered)
    {
        CooldownPosition memory position = positions[tokenId];
        if (position.status != Status.Open) revert UnknownPosition();
        address forceCloseReceiver = receiver == address(0) ? position.receiver : receiver;
        if (forceCloseReceiver == address(0)) revert ZeroReceiver();

        uint256 usdeReceived = _unstakeUSDe(position.proxy);
        usde.safeTransfer(forceCloseReceiver, usdeReceived);
        if (callbackData.length > 0) {
            IYLiquidAdapterCallbackReceiver(forceCloseReceiver).onYLiquidAdapterCallback(
                CALLBACK_PHASE_FORCE_CLOSE_USDE, owner, address(usde), usdeReceived, callbackData
            );
        }

        loanAsset.safeTransferFrom(forceCloseReceiver, market, amountOwed);
        _closePosition(tokenId);
        amountRecovered = amountOwed;
        emit PositionForceClosed(tokenId, forceCloseReceiver, usdeReceived, amountRecovered, position.cooldownEnd);
        _emitStandardizedClose(tokenId, owner, forceCloseReceiver, CloseType.ForceClose, usdeReceived, amountRecovered);
    }

    function positionView(uint256 tokenId) external view returns (PositionView memory viewData) {
        CooldownPosition memory position = positions[tokenId];
        (address owner,,,,,, uint64 expectedEndTime,) = IYLiquidMarketPositionReader(market).positions(tokenId);
        uint64 expectedUnlockTime = position.cooldownEnd == 0 ? expectedEndTime : position.cooldownEnd;

        viewData = PositionView({
            owner: owner,
            receiver: position.receiver,
            proxy: address(position.proxy),
            loanAsset: address(loanAsset),
            collateralAsset: address(sUSDe),
            settlementAsset: address(usde),
            principal: position.principal,
            collateralAmount: position.susdeLocked,
            expectedSettlementAmount: position.usdeExpected,
            expectedUnlockTime: expectedUnlockTime,
            referenceId: 0,
            status: PositionStatus(uint8(position.status))
        });
    }

    function _closePosition(uint256 tokenId) internal {
        positions[tokenId].status = Status.Closed;
    }

    function _unstakeUSDe(AdapterProxy proxy) internal returns (uint256 usdeReceived) {
        uint256 usdeBefore = usde.balanceOf(address(this));
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);
        calls[0] = AdapterProxy.Call({
            target: address(sUSDe),
            value: 0,
            data: abi.encodeCall(IsUSDe.unstake, (address(this)))
        });
        proxy.execute(calls);
        usdeReceived = usde.balanceOf(address(this)) - usdeBefore;
        require(usdeReceived > 0, "zero usde");
    }

    function _emitStandardizedOpen(
        uint256 tokenId,
        address owner,
        address receiver,
        uint256 principal,
        uint256 collateralAmount,
        uint256 expectedSettlementAmount,
        uint64 expectedUnlockTime
    ) internal {
        emit StandardizedPositionOpened(
            tokenId,
            owner,
            receiver,
            address(loanAsset),
            address(sUSDe),
            address(usde),
            principal,
            collateralAmount,
            expectedSettlementAmount,
            expectedUnlockTime,
            0
        );
    }

    function _emitStandardizedClose(
        uint256 tokenId,
        address owner,
        address receiver,
        CloseType closeType,
        uint256 settlementAmount,
        uint256 repaidAmount
    ) internal {
        emit StandardizedPositionClosed(
            tokenId,
            owner,
            receiver,
            closeType,
            address(usde),
            settlementAmount,
            repaidAmount,
            PositionStatus.Closed
        );
    }
}
