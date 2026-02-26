// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IYLiquidAdapter, IYLiquidMarketPositionReader} from "../interfaces/IYLiquidAdapter.sol";
import {IYLiquidActionAdapter} from "../interfaces/IYLiquidActionAdapter.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IYLiquidCollateralOracle} from "../interfaces/IYLiquidCollateralOracle.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {AdapterProxy} from "./AdapterProxy.sol";

interface IMarketAssetReader {
    function asset() external view returns (address);
}

contract GenericCollateralAdapter is IYLiquidAdapter, IYLiquidActionAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint64 public constant DEFAULT_MAX_DURATION_SECONDS = 7 days;

    uint8 public constant CALLBACK_PHASE_OPEN = 1;
    uint8 public constant CALLBACK_PHASE_SETTLE = 2;
    uint8 public constant CALLBACK_PHASE_FORCE_CLOSE = 3;

    enum Status {
        None,
        Open,
        Closed
    }

    struct CollateralConfig {
        bool enabled;
        address oracle;
        uint256 maxLtvWad;
    }

    struct Position {
        AdapterProxy proxy;
        address collateralToken;
        uint256 principal;
        uint256 initialCollateralAmount;
        Status status;
    }

    struct OpenCallbackData {
        bytes receiverData;
    }

    struct OpenExecution {
        AdapterProxy proxy;
        address effectiveReceiver;
        uint256 collateralBalance;
    }

    address public immutable MARKET;
    IERC20 public immutable LOAN_ASSET;

    uint64 public maxDurationSeconds;

    mapping(address => CollateralConfig) public collateralConfigs;
    mapping(uint256 => Position) public positions;

    event MaxDurationUpdated(uint64 maxDurationSeconds);
    event CollateralConfigUpdated(
        address indexed collateralToken,
        bool enabled,
        address oracle,
        uint256 maxLtvWad
    );

    modifier onlyMarket() {
        require(msg.sender == MARKET, "not market");
        _;
    }

    constructor(address market_, address loanAsset_) {
        require(market_ != address(0), "zero market");
        require(loanAsset_ != address(0), "zero asset");

        (bool success, bytes memory data) =
            market_.staticcall(abi.encodeWithSelector(IMarketAssetReader.asset.selector));
        if (success && data.length >= 32) {
            require(abi.decode(data, (address)) == loanAsset_, "asset mismatch");
        }

        MARKET = market_;
        LOAN_ASSET = IERC20(loanAsset_);
        maxDurationSeconds = DEFAULT_MAX_DURATION_SECONDS;
    }

    function setMaxDurationSeconds(uint64 maxDurationSeconds_) external {
        require(msg.sender == _management(), "not management");
        require(maxDurationSeconds_ > 0, "invalid duration");
        maxDurationSeconds = maxDurationSeconds_;
        emit MaxDurationUpdated(maxDurationSeconds_);
    }

    function setCollateralConfig(
        address collateralToken,
        bool enabled,
        address oracle,
        uint256 maxLtvWad
    )
        external
    {
        require(msg.sender == _management(), "not management");
        require(collateralToken != address(0), "zero collateral");

        if (!enabled) {
            delete collateralConfigs[collateralToken];
            emit CollateralConfigUpdated(collateralToken, false, address(0), 0);
            return;
        }

        require(oracle != address(0), "zero oracle");
        require(maxLtvWad > 0 && maxLtvWad <= WAD, "bad max ltv");

        collateralConfigs[collateralToken] = CollateralConfig({
            enabled: true,
            oracle: oracle,
            maxLtvWad: maxLtvWad
        });

        emit CollateralConfigUpdated(collateralToken, true, oracle, maxLtvWad);
    }

    function executeOpen(
        uint256 tokenId,
        address owner,
        uint256 amount,
        address collateralToken,
        uint256 collateralAmount,
        address receiver,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint64)
    {
        require(amount > 0 && collateralAmount > 0, "zero amount");
        require(collateralToken != address(0), "zero collateral");

        OpenCallbackData memory openData = abi.decode(callbackData, (OpenCallbackData));
        bytes memory receiverData = openData.receiverData;
        require(collateralConfigs[collateralToken].enabled, "collateral blocked");
        require(receiver != address(0) || receiverData.length == 0, "open zero receiver data");

        OpenExecution memory openExecution;
        openExecution.proxy = new AdapterProxy(address(this));
        openExecution.effectiveReceiver = receiver == address(0) ? owner : receiver;

        LOAN_ASSET.safeTransfer(openExecution.effectiveReceiver, amount);
        if (receiver != address(0) || receiverData.length > 0) {
            _callReceiver(
                openExecution.effectiveReceiver,
                CALLBACK_PHASE_OPEN,
                owner,
                amount,
                collateralAmount,
                receiverData
            );
        }

        IERC20(collateralToken).safeTransferFrom(
            openExecution.effectiveReceiver,
            address(openExecution.proxy),
            collateralAmount
        );

        openExecution.collateralBalance = IERC20(collateralToken).balanceOf(address(openExecution.proxy));
        require(openExecution.collateralBalance >= collateralAmount, "collateral shortfall");
        _ensureHealthyForToken(collateralToken, openExecution.collateralBalance, amount);

        positions[tokenId] = Position({
            proxy: openExecution.proxy,
            collateralToken: collateralToken,
            principal: amount,
            initialCollateralAmount: openExecution.collateralBalance,
            status: Status.Open
        });

        emit PositionOpened(
            tokenId,
            owner,
            openExecution.effectiveReceiver,
            address(LOAN_ASSET),
            amount,
            collateralToken,
            openExecution.collateralBalance
        );
        return maxDurationSeconds;
    }

    function executeSettle(
        uint256 tokenId,
        address owner,
        uint256 amountOwed,
        address collateralToken,
        address receiver,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRepaid)
    {
        Position memory position = positions[tokenId];
        require(position.status == Status.Open, "unknown position");
        require(collateralToken == position.collateralToken, "bad collateral");

        uint256 collateralBalance = IERC20(position.collateralToken).balanceOf(address(position.proxy));
        bool useProxyReceiver = receiver == address(0) && callbackData.length > 0;
        address effectiveReceiver = useProxyReceiver ? address(position.proxy) : (receiver == address(0) ? owner : receiver);
        if (useProxyReceiver) _executeProxyReceiverData(position.proxy, callbackData);
        if (!useProxyReceiver && (receiver != address(0) || callbackData.length > 0)) {
            _callReceiver(
                effectiveReceiver,
                CALLBACK_PHASE_SETTLE,
                owner,
                amountOwed,
                collateralBalance,
                callbackData
            );
        }

        if (useProxyReceiver) {
            require(LOAN_ASSET.balanceOf(address(position.proxy)) >= amountOwed, "insufficient proxy repay");
            ActionCall[] memory repayCalls = new ActionCall[](1);
            repayCalls[0] =
                ActionCall({target: address(LOAN_ASSET), value: 0, data: abi.encodeCall(IERC20.transfer, (MARKET, amountOwed))});
            position.proxy.execute(repayCalls);
        } else {
            LOAN_ASSET.safeTransferFrom(effectiveReceiver, MARKET, amountOwed);
        }

        positions[tokenId].status = Status.Closed;
        _sendProxyBalances(position.proxy, owner, position.collateralToken);

        amountRepaid = amountOwed;
        emit PositionClosed(
            tokenId,
            owner,
            effectiveReceiver,
            address(LOAN_ASSET),
            amountRepaid,
            position.collateralToken,
            collateralBalance
        );
    }

    function executeForceClose(
        uint256 tokenId,
        address owner,
        uint256 amountOwed,
        address collateralToken,
        address receiver,
        bytes calldata callbackData
    )
        external
        onlyMarket
        nonReentrant
        returns (uint256 amountRecovered)
    {
        Position memory position = positions[tokenId];
        require(position.status == Status.Open, "unknown position");
        require(collateralToken == position.collateralToken, "bad collateral");

        uint256 collateralBalance = IERC20(position.collateralToken).balanceOf(address(position.proxy));
        bool useProxyReceiver = receiver == address(0) && callbackData.length > 0;
        address effectiveReceiver = useProxyReceiver ? address(position.proxy) : (receiver == address(0) ? owner : receiver);
        if (useProxyReceiver) _executeProxyReceiverData(position.proxy, callbackData);
        if (!useProxyReceiver && (receiver != address(0) || callbackData.length > 0)) {
            _callReceiver(
                effectiveReceiver,
                CALLBACK_PHASE_FORCE_CLOSE,
                owner,
                amountOwed,
                collateralBalance,
                callbackData
            );
        }

        if (useProxyReceiver) {
            uint256 proxyBalance = LOAN_ASSET.balanceOf(address(position.proxy));
            amountRecovered = proxyBalance < amountOwed ? proxyBalance : amountOwed;
            if (amountRecovered > 0) {
                ActionCall[] memory recoverCalls = new ActionCall[](1);
                recoverCalls[0] = ActionCall({
                    target: address(LOAN_ASSET),
                    value: 0,
                    data: abi.encodeCall(IERC20.transfer, (MARKET, amountRecovered))
                });
                position.proxy.execute(recoverCalls);
            }
        } else {
            amountRecovered = _pullFromReceiver(effectiveReceiver, amountOwed);
        }

        positions[tokenId].status = Status.Closed;
        _sendProxyBalances(position.proxy, owner, position.collateralToken);

        emit PositionClosed(
            tokenId,
            owner,
            effectiveReceiver,
            address(LOAN_ASSET),
            amountRecovered,
            position.collateralToken,
            collateralBalance
        );
    }

    function positionView(uint256 tokenId) external view returns (PositionView memory viewData) {
        Position memory position = positions[tokenId];
        address owner = IYLiquidMarketPositionReader(MARKET).positionOwner(tokenId);
        (,,,,, uint64 expectedEndTime,) = IYLiquidMarketPositionReader(MARKET).positions(tokenId);

        uint256 currentCollateral;
        if (address(position.proxy) != address(0) && position.collateralToken != address(0)) {
            currentCollateral = IERC20(position.collateralToken).balanceOf(address(position.proxy));
        }

        viewData = PositionView({
            owner: owner,
            proxy: address(position.proxy),
            loanAsset: address(LOAN_ASSET),
            collateralAsset: position.collateralToken,
            principal: position.principal,
            collateralAmount: currentCollateral,
            expectedUnlockTime: expectedEndTime,
            referenceId: 0,
            status: PositionStatus(uint8(position.status))
        });
    }

    function rescue(address token) external nonReentrant {
        address management = _management();
        require(msg.sender == management, "not management");
        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }

    function _ensureHealthy(
        address collateralToken,
        CollateralConfig memory config,
        uint256 collateralAmount,
        uint256 debt
    )
        internal
        view
    {
        require(config.enabled, "collateral blocked");
        uint256 collateralValueInLoanAsset =
            IYLiquidCollateralOracle(config.oracle).collateralToAsset(collateralToken, collateralAmount);
        uint256 maxDebt = Math.mulDiv(collateralValueInLoanAsset, config.maxLtvWad, WAD);
        require(debt <= maxDebt, "insolvent position");
    }

    function _ensureHealthyForToken(address collateralToken, uint256 collateralAmount, uint256 debt) internal view {
        CollateralConfig memory config = collateralConfigs[collateralToken];
        require(config.enabled, "collateral blocked");
        _ensureHealthy(collateralToken, config, collateralAmount, debt);
    }

    function _pullFromReceiver(address receiver, uint256 maxAmount) internal returns (uint256 pulled) {
        uint256 receiverBalance = LOAN_ASSET.balanceOf(receiver);
        pulled = receiverBalance < maxAmount ? receiverBalance : maxAmount;
        if (pulled > 0) {
            LOAN_ASSET.safeTransferFrom(receiver, MARKET, pulled);
        }
    }

    function _executeProxyReceiverData(AdapterProxy proxy, bytes memory receiverData) internal {
        ActionCall[] memory calls = abi.decode(receiverData, (ActionCall[]));
        if (calls.length == 0) return;
        proxy.execute(calls);
    }

    function _callReceiver(
        address callbackTarget,
        uint8 phase,
        address owner,
        uint256 amount,
        uint256 collateralAmount,
        bytes memory data
    )
        internal
    {
        IYLiquidAdapterCallbackReceiver(callbackTarget).onYLiquidAdapterCallback(
            phase,
            owner,
            address(LOAN_ASSET),
            amount,
            collateralAmount,
            data
        );
    }

    function _sendProxyBalances(AdapterProxy proxy, address owner, address collateralToken) internal {
        uint256 collateralBalance = IERC20(collateralToken).balanceOf(address(proxy));
        uint256 loanAssetBalance = LOAN_ASSET.balanceOf(address(proxy));
        uint256 callCount = collateralBalance > 0 ? 1 : 0;
        if (loanAssetBalance > 0 && collateralToken != address(LOAN_ASSET)) {
            callCount += 1;
        }
        if (callCount > 0) {
            ActionCall[] memory calls = new ActionCall[](callCount);
            uint256 idx;
            if (collateralBalance > 0) {
                calls[idx] = ActionCall({
                    target: collateralToken,
                    value: 0,
                    data: abi.encodeCall(IERC20.transfer, (owner, collateralBalance))
                });
                idx++;
            }
            if (loanAssetBalance > 0 && collateralToken != address(LOAN_ASSET)) {
                calls[idx] =
                    ActionCall({target: address(LOAN_ASSET), value: 0, data: abi.encodeCall(IERC20.transfer, (owner, loanAssetBalance))});
            }
            proxy.execute(calls);
        }

        uint256 nativeBalance = address(proxy).balance;
        if (nativeBalance > 0) {
            proxy.transferETH(payable(owner), nativeBalance);
        }
    }

    function _management() internal view returns (address) {
        return ITokenizedStrategy(MARKET).management();
    }
}
