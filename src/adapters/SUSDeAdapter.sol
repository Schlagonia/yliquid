// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IYLiquidAdapter, IYLiquidMarketPositionReader} from "../interfaces/IYLiquidAdapter.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IsUSDe} from "../interfaces/IsUSDe.sol";
import {AdapterProxy} from "./AdapterProxy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

interface IMarketAssetReader {
    function asset() external view returns (address);
}


contract SUSDeAdapter is IYLiquidAdapter, ReentrancyGuard {
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
        uint128 principal;
        uint128 susdeLocked;
        uint128 usdeExpected;
        uint64 cooldownEnd;
        Status status;
    }

    uint256 public constant WAD = 1e18;

    address public immutable MARKET;
    IERC20 public immutable ASSET;
    IERC20 public constant USDE = IERC20(0x4c9EDD5852cd905f086C759E8383e09bff1E68B3);
    IsUSDe public constant SUSDE = IsUSDe(0x9D39A5DE30e57443BfF2A8307A4256c8797A3497);

    uint256 public immutable USDE_PRECISION;

    /// @notice The min rate of USDe to loan asset
    uint256 public minRateWad;

    mapping(uint256 => CooldownPosition) public positions;

    event MinRateUpdated(uint256 minRateWad);

    modifier onlyMarket() {
        require(msg.sender == MARKET, "not market");
        _;
    }

    constructor(address _market, uint256 _minRateWad) {
        require(_market != address(0), "zero market");

        MARKET = _market;
        address assetAddress = IMarketAssetReader(_market).asset();
        require(assetAddress != address(0), "zero market asset");
        ASSET = IERC20(assetAddress);

        require(_minRateWad > 1e18, "min rate too low");
        minRateWad = _minRateWad;

        USDE_PRECISION =
            10 ** uint256(IERC20Metadata(address(SUSDE)).decimals() - IERC20Metadata(assetAddress).decimals());
    }

    function setMinRate(uint256 _minRateWad) external {
        require(msg.sender == ITokenizedStrategy(MARKET).management(), "not management");
        require(_minRateWad > 1e18, "min rate too low");
        minRateWad = _minRateWad;
        emit MinRateUpdated(_minRateWad);
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
        require(amount > 0, "zero amount");
        require(receiver != address(0), "zero receiver");
        require(collateralAmount > 0, "zero amount");

        uint256 usdeExpected = SUSDE.previewRedeem(collateralAmount);
        require(usdeExpected >= amount * USDE_PRECISION * minRateWad / WAD, "min rate not met");

        ASSET.safeTransfer(receiver, amount);
        IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_OPEN_USDC,
            owner,
            address(ASSET),
            amount,
            collateralAmount,
            callbackData
        );

        AdapterProxy proxy = new AdapterProxy(address(this));

        SUSDE.safeTransferFrom(receiver, address(proxy), collateralAmount);

        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);

        calls[0] = AdapterProxy.Call({
            target: address(SUSDE),
            value: 0,
            data: abi.encodeCall(IsUSDe.cooldownShares, collateralAmount)
        });

        proxy.execute(calls);

        expectedDurationSeconds = SUSDE.cooldownDuration();
        uint64 cooldownEnd = uint64(block.timestamp + expectedDurationSeconds);
        positions[tokenId] = CooldownPosition({
            proxy: proxy,
            principal: uint128(amount),
            susdeLocked: uint128(collateralAmount),
            usdeExpected: uint128(usdeExpected),
            cooldownEnd: cooldownEnd,
            status: Status.Open
        });

        _emitPositionOpened(tokenId, owner, receiver, amount, collateralAmount);
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
        require(position.status == Status.Open, "unknown position");
        require(receiver != address(0), "zero receiver");

        uint256 usdeReceived = _unstakeUSDe(position.proxy);

        USDE.safeTransfer(receiver, usdeReceived);
        IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_SETTLE_USDE, owner, address(USDE), usdeReceived, position.susdeLocked, callbackData
        );

        ASSET.safeTransferFrom(receiver, MARKET, amountOwed);

        _closePosition(tokenId);
        amountRepaid = amountOwed;
        _emitPositionClosed(tokenId, owner, receiver, amountRepaid, position.susdeLocked);
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
        require(position.status == Status.Open, "unknown position");
        require(receiver != address(0), "zero receiver");

        uint256 usdeReceived = _unstakeUSDe(position.proxy);
        USDE.safeTransfer(receiver, usdeReceived);
        if (callbackData.length > 0) {
            IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
                CALLBACK_PHASE_FORCE_CLOSE_USDE, owner, address(USDE), usdeReceived, position.susdeLocked, callbackData
            );
        }

        amountRecovered = _pullFromReceiver(receiver, amountOwed);
        _closePosition(tokenId);
        _emitPositionClosed(tokenId, owner, receiver, amountRecovered, position.susdeLocked);
    }

    function positionView(uint256 tokenId) external view returns (PositionView memory viewData) {
        CooldownPosition memory position = positions[tokenId];
        address owner = IYLiquidMarketPositionReader(MARKET).positionOwner(tokenId);
        (,,,,, uint64 expectedEndTime,) = IYLiquidMarketPositionReader(MARKET).positions(tokenId);
        uint64 expectedUnlockTime = position.cooldownEnd == 0 ? expectedEndTime : position.cooldownEnd;

        viewData = PositionView({
            owner: owner,
            proxy: address(position.proxy),
            loanAsset: address(ASSET),
            collateralAsset: address(SUSDE),
            principal: position.principal,
            collateralAmount: position.susdeLocked,
            expectedUnlockTime: expectedUnlockTime,
            referenceId: 0,
            status: PositionStatus(uint8(position.status))
        });
    }

    function _closePosition(uint256 tokenId) internal {
        positions[tokenId].status = Status.Closed;
    }

    function _pullFromReceiver(address receiver, uint256 maxAmount) internal returns (uint256 pulled) {
        uint256 receiverBalance = ASSET.balanceOf(receiver);
        pulled = receiverBalance < maxAmount ? receiverBalance : maxAmount;

        if (pulled > 0) {
            ASSET.safeTransferFrom(receiver, MARKET, pulled);
        }
    }

    function _unstakeUSDe(AdapterProxy proxy) internal returns (uint256 usdeReceived) {
        uint256 usdeBefore = USDE.balanceOf(address(this));
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);
        calls[0] = AdapterProxy.Call({
            target: address(SUSDE),
            value: 0,
            data: abi.encodeCall(IsUSDe.unstake, (address(this)))
        });
        proxy.execute(calls);
        usdeReceived = USDE.balanceOf(address(this)) - usdeBefore;
        require(usdeReceived > 0, "zero usde");
    }

    function _emitPositionOpened(
        uint256 tokenId,
        address owner,
        address receiver,
        uint256 amount,
        uint256 collateralAmount
    ) internal {
        emit PositionOpened(
            tokenId,
            owner,
            receiver,
            address(ASSET),
            amount,
            address(SUSDE),
            collateralAmount
        );
    }

    function _emitPositionClosed(
        uint256 tokenId,
        address owner,
        address receiver,
        uint256 amount,
        uint256 collateralAmount
    ) internal {
        emit PositionClosed(
            tokenId,
            owner,
            receiver,
            address(ASSET),
            amount,
            address(SUSDE),
            collateralAmount
        );
    }

    function rescue(address token) external nonReentrant {
        address management = ITokenizedStrategy(MARKET).management();
        require(msg.sender == management, "not management");

        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }
}
