// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IYLiquidAdapter, IYLiquidMarketPositionReader} from "../interfaces/IYLiquidAdapter.sol";
import {AdapterProxy} from "./AdapterProxy.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IWeETH} from "../interfaces/IWeETH.sol";
import {IEtherFiLiquidityPool} from "../interfaces/IEtherFiLiquidityPool.sol";
import {IEtherFiWithdrawRequestNFT} from "../interfaces/IEtherFiWithdrawRequestNFT.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

contract WeETHUnwindAdapter is IYLiquidAdapter, ReentrancyGuard {
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
        uint128 principal;
        uint128 collateralAmount;
        uint256 requestId;
        Status status;
    }

    IEtherFiLiquidityPool internal constant LIQUIDITY_POOL =
        IEtherFiLiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);

    IEtherFiWithdrawRequestNFT internal constant WITHDRAW_REQUEST_NFT =
        IEtherFiWithdrawRequestNFT(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);

    address public immutable MARKET;
    IWETH9 public constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant EETH = IERC20(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    IWeETH public constant WEETH = IWeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);

    /// @notice The min rate of WETH to eETH
    uint256 public minRateWad;
    uint64 public maxDurationSeconds;

    mapping(uint256 => Position) public positions;

    event MaxDurationUpdated(uint64 maxDurationSeconds);
    event MinRateUpdated(uint256 minRateWad);

    modifier onlyMarket() {
        require(msg.sender == MARKET, "not market");
        _;
    }

    constructor(address _market, uint256 _minRateWad) {
        require(_market != address(0), "zero market");
        require(_minRateWad > 1e18, "min rate too low");

        MARKET = _market;
        minRateWad = _minRateWad;
        maxDurationSeconds = DEFAULT_MAX_DURATION_SECONDS;
    }

    receive() external payable {}

    function setMaxDurationSeconds(uint64 _maxDurationSeconds) external {
        require(msg.sender == ITokenizedStrategy(MARKET).management(), "not authorized");
        require(_maxDurationSeconds > 0, "invalid duration");
        maxDurationSeconds = _maxDurationSeconds;
        emit MaxDurationUpdated(_maxDurationSeconds);
    }

    function setMinRate(uint256 _minRateWad) external {
        require(msg.sender == ITokenizedStrategy(MARKET).management(), "not authorized");
        require(_minRateWad > 1e18, "min rate too low");
        minRateWad = _minRateWad;
        emit MinRateUpdated(_minRateWad);
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
        require(asset == address(WETH), "bad asset");
        require(receiver != address(0), "zero receiver");
        require(amount > 0 && collateralAmount > 0, "zero amount");

        uint256 eEthAmount = WEETH.getEETHByWeETH(collateralAmount);
        require(eEthAmount >= amount * minRateWad / WAD, "slippage");

        WETH.safeTransfer(receiver, amount);
        IYLiquidAdapterCallbackReceiver(receiver).onYLiquidAdapterCallback(
            CALLBACK_PHASE_OPEN_WETH,
            owner,
            address(WETH),
            amount,
            collateralAmount,
            callbackData
        );

        AdapterProxy proxy = new AdapterProxy(address(this));

        WEETH.safeTransferFrom(receiver, address(proxy), collateralAmount);
        uint256 requestId = _withdrawEEth(proxy, collateralAmount);

        require(requestId > 0, "missing request id");

        positions[tokenId] = Position({
            proxy: proxy,
            principal: uint128(amount),
            collateralAmount: uint128(collateralAmount),
            requestId: requestId,
            status: Status.Open
        });

        expectedDurationSeconds = maxDurationSeconds;
        _emitPositionOpened(tokenId, owner, receiver, amount, collateralAmount);
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
        require(asset == address(WETH), "bad asset");

        Position memory position = positions[tokenId];
        require(position.status == Status.Open, "unknown position");
        uint256 claimedEth = _claimWithdrawal(position.proxy, position.requestId);
        amountRepaid = _wrapAndDistribute(position.proxy, owner, claimedEth, amountOwed);

        positions[tokenId].status = Status.Closed;
        _emitPositionClosed(tokenId, owner, owner, amountRepaid, position.collateralAmount);
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
        require(asset == address(WETH), "bad asset");

        Position memory position = positions[tokenId];
        require(position.status == Status.Open, "unknown position");
        uint256 claimedEth = _claimWithdrawal(position.proxy, position.requestId);
        amountRecovered = _wrapAndDistribute(position.proxy, owner, claimedEth, amountOwed);
        positions[tokenId].status = Status.Closed;
        _emitPositionClosed(tokenId, owner, owner, amountRecovered, position.collateralAmount);
    }

    function positionView(uint256 tokenId) external view returns (PositionView memory viewData) {
        Position memory position = positions[tokenId];
        address owner = IYLiquidMarketPositionReader(MARKET).positionOwner(tokenId);
        (,,,,, uint64 expectedEndTime,) = IYLiquidMarketPositionReader(MARKET).positions(tokenId);

        viewData = PositionView({
            owner: owner,
            proxy: address(position.proxy),
            loanAsset: address(WETH),
            collateralAsset: address(WEETH),
            principal: position.principal,
            collateralAmount: position.collateralAmount,
            expectedUnlockTime: expectedEndTime,
            referenceId: position.requestId,
            status: PositionStatus(uint8(position.status))
        });
    }

    function _withdrawEEth(AdapterProxy proxy, uint256 collateralAmount) internal returns (uint256 requestId) {
        AdapterProxy.Call[] memory unwrapCalls = new AdapterProxy.Call[](1);
        unwrapCalls[0] =
            AdapterProxy.Call({target: address(WEETH), value: 0, data: abi.encodeCall(IWeETH.unwrap, collateralAmount)});
        proxy.execute(unwrapCalls);

        uint256 eEthAmount = EETH.balanceOf(address(proxy));
        require(eEthAmount > 0, "zero eeth");

        AdapterProxy.Call[] memory withdrawCalls = new AdapterProxy.Call[](2);
        withdrawCalls[0] = AdapterProxy.Call({
            target: address(EETH),
            value: 0,
            data: abi.encodeCall(IERC20.approve, (address(LIQUIDITY_POOL), eEthAmount))
        });
        withdrawCalls[1] = AdapterProxy.Call({
            target: address(LIQUIDITY_POOL),
            value: 0,
            data: abi.encodeCall(IEtherFiLiquidityPool.requestWithdraw, (address(proxy), eEthAmount))
        });

        bytes[] memory results = proxy.execute(withdrawCalls);
        requestId = abi.decode(results[1], (uint256));
    }

    function _claimWithdrawal(AdapterProxy proxy, uint256 requestId) internal returns (uint256 claimedEth) {
        AdapterProxy.Call[] memory calls = new AdapterProxy.Call[](1);
        calls[0] = AdapterProxy.Call({
            target: address(WITHDRAW_REQUEST_NFT),
            value: 0,
            data: abi.encodeCall(IEtherFiWithdrawRequestNFT.claimWithdraw, (requestId))
        });
        proxy.execute(calls);

        claimedEth = address(proxy).balance;
        require(claimedEth > 0, "zero amount");
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
            target: address(WETH),
            value: claimedEth,
            data: abi.encodeCall(IWETH9.deposit, ())
        });
        calls[1] = AdapterProxy.Call({
            target: address(WETH),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (address(MARKET), paidToMarket))
        });

        if (surplus > 0) {
            calls[2] = AdapterProxy.Call({
                target: address(WETH),
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (receiver, surplus))
            });
        }

        proxy.execute(calls);
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
            address(WETH),
            amount,
            address(WEETH),
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
            address(WETH),
            amount,
            address(WEETH),
            collateralAmount
        );
    }

    function rescue(address token) external nonReentrant {
        address management = ITokenizedStrategy(MARKET).management();
        require(msg.sender == management, "not management");

        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }
}
