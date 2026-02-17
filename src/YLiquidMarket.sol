// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IYLiquidAdapter} from "./interfaces/IYLiquidAdapter.sol";
import {IYLiquidRateModel} from "./interfaces/IYLiquidRateModel.sol";
import {YLiquidPositionNFT} from "./YLiquidPositionNFT.sol";

contract YLiquidMarket is BaseHealthCheck, ReentrancyGuard {
    using SafeERC20 for ERC20;
    using SafeERC20 for IERC20;

    enum PositionState {
        Requested,
        Active,
        ReadyToSettle,
        Closed,
        Defaulted
    }

    struct Position {
        address asset;
        address adapter;
        uint128 principal;
        uint32 riskPremiumBps;
        uint64 startTime;
        uint64 expectedEndTime;
        PositionState state;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FORCE_CLOSE_DELAY_MULTIPLIER_BPS = 15_000; // 1.5x expected duration

    IVault public yearnVault;
    IYLiquidRateModel public rateModel;
    YLiquidPositionNFT public immutable POSITION_NFT;

    address public idleStrategy;
    uint256 public totalPrincipalActive;
    uint256 public bountyBps;
    bool public paused;

    mapping(address => bool) public allowedAdapters;
    mapping(address => uint32) public adapterRiskPremiumBps;
    mapping(uint256 => Position) public positions;

    event IdleStrategyUpdated(address indexed strategy);
    event PauseUpdated(bool paused);
    event BountyUpdated(uint256 bountyBps);
    event AdapterAllowed(address indexed adapter, bool allowed);
    event AdapterRiskPremiumUpdated(address indexed adapter, uint32 riskPremiumBps);
    event PositionOpened(
        uint256 indexed tokenId,
        address indexed adapter,
        address indexed owner,
        uint256 principal,
        uint64 expectedDurationSeconds
    );
    event PositionSettled(uint256 indexed tokenId, address indexed caller, uint256 repaid);
    event PositionForceClosed(uint256 indexed tokenId, address indexed caller, uint256 recovered, uint256 bounty);


    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(
        address asset_,
        address yearnVault_,
        address rateModel_,
        string memory nftName,
        string memory nftSymbol
    ) BaseHealthCheck(asset_, string.concat(nftName, " Strategy")) {
        require(yearnVault_ != address(0), "zero vault");
        require(rateModel_ != address(0), "zero rate");

        yearnVault = IVault(yearnVault_);
        rateModel = IYLiquidRateModel(rateModel_);
        bountyBps = 100;
        POSITION_NFT = new YLiquidPositionNFT(nftName, nftSymbol, address(this));
    }

    function setIdleStrategy(address strategy) external onlyManagement {
        require(yearnVault.strategies(strategy).activation > 0, "strategy not activated");
        idleStrategy = strategy;
        emit IdleStrategyUpdated(strategy);
    }

    function setRateModel(address rateModel_) external onlyManagement {
        require(rateModel_ != address(0), "zero rate");
        rateModel = IYLiquidRateModel(rateModel_);
    }

    function setPaused(bool paused_) external onlyEmergencyAuthorized {
        paused = paused_;
        emit PauseUpdated(paused_);
    }

    function setBountyBps(uint256 bountyBps_) external onlyManagement {
        require(bountyBps_ <= 1_000, "bounty too high");
        bountyBps = bountyBps_;
        emit BountyUpdated(bountyBps_);
    }

    function setAdapterAllowed(address adapter, bool allowed) external onlyManagement {
        require(adapter != address(0), "zero adapter");
        allowedAdapters[adapter] = allowed;
        emit AdapterAllowed(adapter, allowed);
    }

    function setAdapterRiskPremium(address adapter, uint32 riskPremiumBps) external onlyManagement {
        require(allowedAdapters[adapter], "adapter not allowed");
        require(riskPremiumBps <= BPS, "premium too high");
        adapterRiskPremiumBps[adapter] = riskPremiumBps;
        emit AdapterRiskPremiumUpdated(adapter, riskPremiumBps);
    }

    function openPosition(
        uint256 principal,
        address adapter,
        address receiver,
        uint256 collateralAmount,
        bytes calldata callbackData
    )
        external
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        require(allowedAdapters[adapter], "adapter blocked");
        require(principal > 0, "zero principal");

        address resolvedReceiver = receiver == address(0) ? msg.sender : receiver;
        tokenId = POSITION_NFT.mint(msg.sender);

        totalPrincipalActive += principal;
        _pullForBorrow(principal);
        asset.safeTransfer(adapter, principal);

        uint64 expectedDurationSeconds = IYLiquidAdapter(adapter).executeOpen(
            tokenId, msg.sender, address(asset), principal, resolvedReceiver, collateralAmount, callbackData
        );
        require(expectedDurationSeconds > 0, "zero duration");
        uint256 expectedEndTime = block.timestamp + expectedDurationSeconds;
        require(expectedEndTime <= type(uint64).max, "end overflow");

        positions[tokenId] = Position({
            asset: address(asset),
            adapter: adapter,
            principal: uint128(principal),
            riskPremiumBps: adapterRiskPremiumBps[adapter],
            startTime: uint64(block.timestamp),
            expectedEndTime: uint64(expectedEndTime),
            state: PositionState.Active
        });

        emit PositionOpened(tokenId, adapter, msg.sender, principal, expectedDurationSeconds);
    }

    function positionOwner(uint256 tokenId) external view returns (address) {
        return POSITION_NFT.ownerOf(tokenId);
    }

    function quoteDebt(uint256 tokenId) public view returns (uint256 amountOwed) {
        Position memory position = positions[tokenId];
        require(position.state == PositionState.Active, "bad state");

        uint256 elapsed = block.timestamp - position.startTime;
        uint256 expected = position.expectedEndTime - position.startTime;

        uint256 rateBps = rateModel.borrowRateBps(position.riskPremiumBps, elapsed, expected);
        uint256 accrued = (uint256(position.principal) * rateBps * elapsed) / (BPS * SECONDS_PER_YEAR);
        amountOwed = position.principal + accrued;
    }

    function settleAndRepay(uint256 tokenId, address receiver, bytes calldata callbackData)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amountOwed)
    {
        Position storage position = positions[tokenId];
        require(position.state == PositionState.Active, "bad state");
        require(msg.sender == POSITION_NFT.ownerOf(tokenId), "not owner");

        amountOwed = quoteDebt(tokenId);
        address resolvedReceiver = receiver == address(0) ? msg.sender : receiver;

        uint256 balBefore = asset.balanceOf(address(this));
        IYLiquidAdapter(position.adapter).executeSettle(
            tokenId, msg.sender, address(asset), amountOwed, resolvedReceiver, callbackData
        );
        uint256 balAfter = asset.balanceOf(address(this));
        uint256 repaid = balAfter - balBefore;
        require(repaid >= amountOwed, "insolvent settle");

        position.state = PositionState.Closed;
        totalPrincipalActive -= position.principal;
        POSITION_NFT.burn(tokenId);

        _shiftMarketToIdle(repaid);
        emit PositionSettled(tokenId, msg.sender, repaid);
    }

    function forceClose(uint256 tokenId, address receiver, bytes calldata callbackData)
        external
        onlyManagement
        whenNotPaused
        nonReentrant
        returns (uint256 recovered)
    {
        Position storage position = positions[tokenId];
        require(position.state == PositionState.Active, "bad state");
        uint256 expectedDuration = position.expectedEndTime - position.startTime;
        uint256 forceCloseTime =
            uint256(position.startTime) + ((expectedDuration * FORCE_CLOSE_DELAY_MULTIPLIER_BPS) / BPS);
        require(block.timestamp >= forceCloseTime, "force close too early");

        uint256 amountOwed = quoteDebt(tokenId);
        address resolvedReceiver = receiver == address(0) ? msg.sender : receiver;

        uint256 balBefore = asset.balanceOf(address(this));
        IYLiquidAdapter(position.adapter).executeForceClose(
            tokenId, POSITION_NFT.ownerOf(tokenId), address(asset), amountOwed, resolvedReceiver, callbackData
        );
        uint256 balAfter = asset.balanceOf(address(this));
        recovered = balAfter - balBefore;

        uint256 surplus = recovered > amountOwed ? recovered - amountOwed : 0;
        uint256 bounty = (surplus * bountyBps) / BPS;
        if (bounty > 0) {
            asset.safeTransfer(msg.sender, bounty);
        }

        position.state = PositionState.Defaulted;
        totalPrincipalActive -= position.principal;
        POSITION_NFT.burn(tokenId);

        _shiftMarketToIdle(recovered - bounty);

        emit PositionForceClosed(tokenId, msg.sender, recovered, bounty);
    }

    function availableLiquidity() external view returns (uint256) {
        uint256 max = 
            asset.balanceOf(address(this)) +
            yearnVault.totalIdle() +
            Math.min(_currentDebt(idleStrategy), IVault(idleStrategy).convertToAssets(IVault(idleStrategy).maxRedeem(address(yearnVault))));
        
        return Math.min(max, yearnVault.strategies(address(this)).max_debt);
    }

    function utilizationBps() public view returns (uint256) {
        return (totalPrincipalActive * BPS) / yearnVault.totalAssets();
    }

    function _pullForBorrow(uint256 amount) internal {
        uint256 bal = asset.balanceOf(address(this));
        if (bal >= amount) return;

        _shiftIdleToMarket(amount - bal);
        require(asset.balanceOf(address(this)) >= amount, "insufficient liquidity");
    }

    function _shiftIdleToMarket(uint256 amount) internal {
        if (amount == 0) return;

        uint256 currentIdleBal = yearnVault.totalIdle();

        if (currentIdleBal < amount) {
            uint256 currentIdleDebt = _currentDebt(idleStrategy);
            uint256 shift = amount - currentIdleBal;
            shift = shift > currentIdleDebt ? currentIdleDebt : shift;

            yearnVault.update_debt(idleStrategy, currentIdleDebt - shift);
        }

        yearnVault.update_debt(address(this), _currentDebt(address(this)) + amount);
    }

    function _shiftMarketToIdle(uint256) internal {
        // Max's will take care of exact amounts.
        yearnVault.update_debt(address(this), 0);
        yearnVault.update_debt(idleStrategy, type(uint256).max);
    }

    function _currentDebt(address strategy) internal view returns (uint256) {
        return yearnVault.strategies(strategy).current_debt;
    }

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256) internal view override {}

    function _harvestAndReport() internal view override returns (uint256) {
        return asset.balanceOf(address(this)) + totalPrincipalActive;
    }

    function availableDepositLimit(address owner) public view override returns (uint256) {
        if (owner == address(yearnVault)) return type(uint256).max;

        return 0;
    }

    function availableWithdrawLimit(address) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function rescue(address token) external onlyManagement {
        require(token != address(asset), "cannot rescue asset");

        address management = ITokenizedStrategy(address(this)).management();
        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }

}
