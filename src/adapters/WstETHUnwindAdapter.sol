// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYLiquidAdapter} from "../interfaces/IYLiquidAdapter.sol";
import {AdapterProxy} from "./AdapterProxy.sol";
import {IQueue} from "../interfaces/IQueue.sol";
import {ISteth} from "../interfaces/ISteth.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IwstETH} from "../interfaces/IwstETH.sol";
import {IYLiquidAdapterUI, IYLiquidMarketPositionReader} from "../interfaces/IYLiquidAdapterUI.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

contract WstETHUnwindAdapter is IYLiquidAdapter, IYLiquidAdapterUI {
    using SafeERC20 for *;

    uint256 public constant WAD = 1e18;
    uint64 public constant DEFAULT_MAX_DURATION_SECONDS = 7 days;

    uint8 public constant CALLBACK_PHASE_OPEN_WETH = 1;

    enum Status {
        None,
        Open,
        Closed
    }

    struct Position {
        AdapterProxy proxy;
        address receiver;
        uint128 principal;
        uint128 collateralAmount;
        uint256 requestId;
        Status status;
    }

    IQueue internal constant WITHDRAWAL_QUEUE =
        IQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1); // stETH withdrawal queue

    ISteth public constant stETH =
        ISteth(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    address public immutable market;
    IWETH9 public immutable weth;
    IwstETH public immutable wstEth;

    /// @notice The min rate of weth to steth
    uint256 public minRateWad;
    uint64 public maxDurationSeconds;

    mapping(uint256 => Position) public positions;

    uint256 private _lock;

    error NotMarket();
    error NotAuthorized();
    error BadAsset();
    error ZeroReceiver();
    error ZeroAmount();
    error InvalidDuration();
    error UnknownPosition();
    error Slippage();

    event PositionOpened(uint256 indexed tokenId, address indexed receiver, uint256 principal, uint256 wstEthLocked);
    event PositionSettled(uint256 indexed tokenId, address indexed receiver, uint256 wethRecovered, uint256 amountRepaid);
    event PositionForceClosed(
        uint256 indexed tokenId, address indexed receiver, uint256 wethRecovered, uint256 amountRecovered
    );
    event MaxDurationUpdated(uint64 maxDurationSeconds);

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


    constructor(address _market, address _weth, address _wstEth, uint256 _minRateWad) {
        require(_market != address(0), "zero market");
        require(_weth != address(0), "zero weth");
        require(_wstEth != address(0), "zero wsteth");
        require(_minRateWad > 0, "zero min rate");

        market = _market;
        weth = IWETH9(_weth);
        wstEth = IwstETH(_wstEth);
        minRateWad = _minRateWad;
        maxDurationSeconds = DEFAULT_MAX_DURATION_SECONDS;
    }

    receive() external payable {}

    function setMaxDurationSeconds(uint64 _maxDurationSeconds) external {
        if (msg.sender != ITokenizedStrategy(market).management()) revert NotAuthorized();
        if (_maxDurationSeconds == 0) revert InvalidDuration();
        maxDurationSeconds = _maxDurationSeconds;
        emit MaxDurationUpdated(_maxDurationSeconds);
    }

    function executeOpen(
        uint256 tokenId,
        address owner,
        address asset,
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
        if (asset != address(weth)) revert BadAsset();
        if (receiver == address(0)) revert ZeroReceiver();
        if (amount == 0 || collateralAmount == 0) revert ZeroAmount();

        uint256 stEthAmount = wstEth.getStETHByWstETH(collateralAmount);
        if (stEthAmount < amount * minRateWad / WAD) revert Slippage();

        weth.safeTransfer(receiver, amount);
        IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_OPEN_WETH, owner, address(weth), amount, callbackData
        );

        AdapterProxy proxy = new AdapterProxy(address(this));

        wstEth.safeTransferFrom(receiver, address(proxy), collateralAmount);
        uint256 requestId = _withdrawStEth(proxy, collateralAmount, stEthAmount);
        
        require(requestId > 0, "request id");

        positions[tokenId] = Position({
            proxy: proxy,
            receiver: receiver,
            principal: uint128(amount),
            collateralAmount: uint128(collateralAmount),
            requestId: requestId,
            status: Status.Open
        });

        expectedDurationSeconds = maxDurationSeconds;
        uint64 expectedUnlockTime = uint64(block.timestamp + expectedDurationSeconds);
        emit PositionOpened(tokenId, receiver, amount, collateralAmount);
        _emitStandardizedOpen(tokenId, owner, receiver, amount, collateralAmount, stEthAmount, expectedUnlockTime, requestId);
    }

    function executeSettle(
        uint256 tokenId,
        address owner,
        address asset,
        uint256 amountOwed,
        address,
        bytes calldata
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRepaid)
    {
        if (asset != address(weth)) revert BadAsset();

        Position memory position = positions[tokenId];
        if (position.status != Status.Open) revert UnknownPosition();
        uint256 claimedEth = _claimWithdrawal(position.proxy, position.requestId);
        amountRepaid = _wrapAndDistribute(position.proxy, owner, claimedEth, amountOwed);

        positions[tokenId].status = Status.Closed;
        emit PositionSettled(tokenId, owner, claimedEth, amountRepaid);
        _emitStandardizedClose(tokenId, owner, owner, CloseType.Settle, claimedEth, amountRepaid);
    }

    function executeForceClose(
        uint256 tokenId,
        address owner,
        address asset,
        uint256 amountOwed,
        address,
        bytes calldata
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRecovered)
    {
        if (asset != address(weth)) revert BadAsset();

        Position memory position = positions[tokenId];
        if (position.status != Status.Open) revert UnknownPosition();
        uint256 claimedEth = _claimWithdrawal(position.proxy, position.requestId);
        amountRecovered = _wrapAndDistribute(position.proxy, owner, claimedEth, amountOwed);
        positions[tokenId].status = Status.Closed;
        emit PositionForceClosed(tokenId, owner, claimedEth, amountRecovered);
        _emitStandardizedClose(tokenId, owner, owner, CloseType.ForceClose, claimedEth, amountRecovered);
    }

    function positionView(uint256 tokenId) external view returns (PositionView memory viewData) {
        Position memory position = positions[tokenId];
        (address owner,,,,,, uint64 expectedEndTime,) = IYLiquidMarketPositionReader(market).positions(tokenId);
        uint256 expectedSettlementAmount =
            position.collateralAmount == 0 ? 0 : wstEth.getStETHByWstETH(position.collateralAmount);

        viewData = PositionView({
            owner: owner,
            receiver: position.receiver,
            proxy: address(position.proxy),
            loanAsset: address(weth),
            collateralAsset: address(wstEth),
            settlementAsset: address(weth),
            principal: position.principal,
            collateralAmount: position.collateralAmount,
            expectedSettlementAmount: expectedSettlementAmount,
            expectedUnlockTime: expectedEndTime,
            referenceId: position.requestId,
            status: PositionStatus(uint8(position.status))
        });
    }

    function _withdrawStEth(AdapterProxy proxy, uint256 collateralAmount, uint256 stEthAmount) internal returns (uint256 requestId) {
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](3);

        calls[0] = AdapterProxy.Call({
            target: address(wstEth),
            value: 0,
            data: abi.encodeCall(IwstETH.unwrap, collateralAmount)
        });

        calls[1] = AdapterProxy.Call({
            target: address(stETH),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(WITHDRAWAL_QUEUE), stEthAmount))
        });

        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = stEthAmount;

        calls[2] = AdapterProxy.Call({
            target: address(WITHDRAWAL_QUEUE),
            value: 0,
            data: abi.encodeCall(IQueue.requestWithdrawals, (_amounts, address(proxy)))
        });

        bytes[] memory results = proxy.execute(calls);
        uint256[] memory requestIds = abi.decode(results[2], (uint256[]));
        require(requestIds.length > 0, "missing request");
        requestId = requestIds[0];
    }

    function _claimWithdrawal(AdapterProxy proxy, uint256 requestId) internal returns (uint256 claimedEth) {
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);
        calls[0] = AdapterProxy.Call({
            target: address(WITHDRAWAL_QUEUE),
            value: 0,
            data: abi.encodeCall(IQueue.claimWithdrawal, (requestId))
        });
        proxy.execute(calls);

        claimedEth = address(proxy).balance;
        if (claimedEth == 0) revert ZeroAmount();
    }

    function _wrapAndDistribute(AdapterProxy proxy, address receiver, uint256 claimedEth, uint256 amountOwed)
        internal
        returns (uint256 paidToMarket)
    {
        paidToMarket = amountOwed > claimedEth ? claimedEth : amountOwed;
        uint256 surplus = claimedEth - paidToMarket;

        uint256 callCount = surplus > 0 ? 3 : 2;
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](callCount);
        calls[0] = AdapterProxy.Call({
            target: address(weth),
            value: claimedEth,
            data: abi.encodeCall(IWETH9.deposit, ())
        });
        calls[1] = AdapterProxy.Call({
            target: address(weth),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (address(market), paidToMarket))
        });

        if (surplus > 0) {
            calls[2] = AdapterProxy.Call({
                target: address(weth),
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (receiver, surplus))
            });
        }

        proxy.execute(calls);
    }

    function _emitStandardizedOpen(
        uint256 tokenId,
        address owner,
        address receiver,
        uint256 principal,
        uint256 collateralAmount,
        uint256 expectedSettlementAmount,
        uint64 expectedUnlockTime,
        uint256 referenceId
    ) internal {
        emit StandardizedPositionOpened(
            tokenId,
            owner,
            receiver,
            address(weth),
            address(wstEth),
            address(weth),
            principal,
            collateralAmount,
            expectedSettlementAmount,
            expectedUnlockTime,
            referenceId
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
            address(weth),
            settlementAmount,
            repaidAmount,
            PositionStatus.Closed
        );
    }

}
