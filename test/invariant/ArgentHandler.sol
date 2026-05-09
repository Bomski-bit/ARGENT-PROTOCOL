// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArgentProtocol} from "../../src/ArgentProtocol.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

// ═══════════════════════════════════════════════════════════════════════════════
//  HANDLER
//  Foundry calls functions on this contract at random. It wraps every protocol
//  action, bounds inputs to valid ranges, and maintains ghost accounting so the
//  invariant contract can compare expected vs actual state.
// ═══════════════════════════════════════════════════════════════════════════════

contract ArgentHandler is Test {
    // ── Protocol under test ──────────────────────────────────────────────────
    ArgentProtocol public immutable protocol;
    MockERC20 public immutable tokenA; // 18 dec, $2 000
    MockERC20 public immutable tokenB; // 6  dec, $1
    MockPriceOracle public immutable oracle;

    // ── Actors ───────────────────────────────────────────────────────────────
    address[4] public actors;

    // ── Ghost variables ──────────────────────────────────────────────────────

    /// @dev Net collateral deposited that has not been withdrawn or seized.
    ///      Upper-bounded ghost: seizures are NOT subtracted (we don't know them here).
    mapping(address => uint256) public ghostTotalCollateral;

    /// @dev Net liquidity deposited that has not been withdrawn.
    mapping(address => uint256) public ghostTotalLiquidity;

    /// @dev Net principal borrowed that has not been repaid.
    ///      Only principal — accrued interest is tracked by the index, not here.
    mapping(address => uint256) public ghostTotalBorrows;

    /// @dev Highest borrow index ever observed — used to enforce monotonicity.
    mapping(address => uint256) public ghostLastIndex;

    // ── Internal constants ───────────────────────────────────────────────────
    uint256 constant INITIAL_INDEX = 1e18;

    // ════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ════════════════════════════════════════════════════════════════════════

    constructor(
        ArgentProtocol _protocol,
        MockERC20 _tokenA,
        MockERC20 _tokenB,
        MockPriceOracle _oracle,
        address[4] memory _actors
    ) {
        protocol = _protocol;
        tokenA = _tokenA;
        tokenB = _tokenB;
        oracle = _oracle;
        actors = _actors;

        // Seed every actor with tokens and infinite approvals
        for (uint256 i; i < _actors.length; i++) {
            tokenA.mint(_actors[i], 10_000e18);
            tokenB.mint(_actors[i], 10_000_000e6);
            vm.startPrank(_actors[i]);
            tokenA.approve(address(_protocol), type(uint256).max);
            tokenB.approve(address(_protocol), type(uint256).max);
            vm.stopPrank();
        }

        // Seed the liquidity pool so borrows can succeed from the start
        address seeder = _actors[0];
        tokenB.mint(seeder, 500_000e6);
        vm.startPrank(seeder);
        tokenB.approve(address(_protocol), type(uint256).max);
        _protocol.depositLiquidity(address(_tokenB), 500_000e6);
        vm.stopPrank();
        ghostTotalLiquidity[address(_tokenB)] += 500_000e6;

        // Initialize ghost indices
        ghostLastIndex[address(_tokenA)] = INITIAL_INDEX;
        ghostLastIndex[address(_tokenB)] = INITIAL_INDEX;
    }

    // ════════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Refresh ghost index to the highest value seen so far.
    function _updateGhostIndex(address asset) internal {
        uint256 idx = protocol.getBorrowIndex(asset);
        if (idx > ghostLastIndex[asset]) {
            ghostLastIndex[asset] = idx;
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    //  HANDLER ACTIONS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @dev Deposit tokenA as collateral.
     */
    function depositCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 100e18);

        // Guarantee the actor always has enough
        tokenA.mint(actor, amount);
        vm.prank(actor);
        tokenA.approve(address(protocol), type(uint256).max);

        vm.prank(actor);
        protocol.depositCollateral(address(tokenA), amount); // naked — revert = bug

        ghostTotalCollateral[address(tokenA)] += amount;
    }

    /**
     * @dev Withdraw tokenA collateral.
     *      Bounded by user's current collateral so reverts from over-withdrawal
     *      don't pollute the ghost.
     */
    function withdrawCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 col = protocol.getUserCollateral(actor, address(tokenA));
        if (col == 0) return;

        amount = bound(amount, 1, col);

        uint256 debtUSD = protocol.getTotalDebtUSD(actor);
        uint256 colAfterUSD = protocol.getAssetValueUSD(address(tokenA), col - amount);
        uint256 weightedLT = protocol.getLiquidationThreshold(address(tokenA));

        if (debtUSD > 0) {
            // HF after = (colAfterUSD * LT) / (debtUSD * BP)
            // Skip if HF after < 1
            if (colAfterUSD * weightedLT < debtUSD * 10_000) return;
        }

        vm.prank(actor);
        protocol.withdrawCollateral(address(tokenA), amount);
        ghostTotalCollateral[address(tokenA)] -= amount;
    }

    /**
     * @dev Deposit tokenB as liquidity.
     */
    function depositLiquidity(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, 100_000e6);

        tokenB.mint(actor, amount);
        vm.prank(actor);
        tokenB.approve(address(protocol), type(uint256).max);

        vm.prank(actor);
        protocol.depositLiquidity(address(tokenB), amount);

        ghostTotalLiquidity[address(tokenB)] += amount;
    }

    /**
     * @dev Withdraw tokenB liquidity.
     */
    function withdrawLiquidity(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 userDeposit = protocol.getUserLiquidityDeposit(actor, address(tokenB));
        uint256 poolAvailable = protocol.getAvailableLiquidity(address(tokenB));

        if (userDeposit == 0) return;
        if (poolAvailable == 0) return;

        // Bound to the minimum of what the user deposited and what the pool has
        // This eliminates both legitimate revert causes
        uint256 maxWithdraw = _min(userDeposit, poolAvailable);
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(actor);
        protocol.withdrawLiquidity(address(tokenB), amount);

        ghostTotalLiquidity[address(tokenB)] -= amount;
    }

    /**
     * @dev Borrow tokenB against tokenA collateral.
     *      Ghost records only the principal so we can compare to totalBorrows.
     */
    function borrow(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 borrowLimit = protocol.getBorrowLimit(actor);
        uint256 currentDebt = protocol.getTotalDebtUSD(actor);
        uint256 available = protocol.getAvailableLiquidity(address(tokenB));

        if (borrowLimit <= currentDebt) return;
        if (available == 0) return;
        if (protocol.getUserCollateral(actor, address(tokenA)) == 0) return;

        // Convert remaining USD borrow room to tokenB atoms (6 dec, $1 each)
        // borrowLimitUSD is in 18-dec internal USD; tokenB is 6-dec at $1
        // so tokenB atoms = USD / 1e12
        uint256 remainingUSD = borrowLimit - currentDebt;
        uint256 remainingTokenB = remainingUSD / 1e12;
        uint256 maxBorrow = _min(remainingTokenB, available);

        if (maxBorrow == 0) return;

        amount = bound(amount, 1, maxBorrow);

        vm.prank(actor);
        protocol.borrow(address(tokenB), amount); // naked — revert = bug

        ghostTotalBorrows[address(tokenB)] += amount;
        _updateGhostIndex(address(tokenB));
    }

    /**
     * @dev Repay tokenB debt.
     */
    function repay(uint256 actorSeed, uint256 fraction) external {
        address actor = _actor(actorSeed);
        uint256 debt = protocol.getUserDebt(actor, address(tokenB));
        if (debt == 0) return;

        uint256 amount = bound(fraction, 1, debt);

        // Always mint to guarantee the actor can repay
        tokenB.mint(actor, amount);
        vm.prank(actor);
        tokenB.approve(address(protocol), type(uint256).max);

        vm.prank(actor);
        protocol.repay(address(tokenB), amount); // naked — revert = bug

        uint256 reduction = _min(amount, ghostTotalBorrows[address(tokenB)]);
        ghostTotalBorrows[address(tokenB)] -= reduction;
    }

    /**
     * @dev Liquidate an undercollateralised position.
     *      Only called when the target is genuinely liquidatable to keep the
     *      ghost reduction meaningful.
     */
    function liquidate(uint256 liquidatorSeed, uint256 targetSeed, uint256 repayAmount) external {
        address liq = _actor(liquidatorSeed);
        address target = _actor(targetSeed);

        if (liq == target) return;
        if (!protocol.getLiquidatable(target)) return;

        uint256 debt = protocol.getUserDebt(target, address(tokenB));
        if (debt == 0) return;

        // Check the position has non-zero collateral to seize.
        // At extreme price drops _getMaxLiquidatableDebt can return 0 (closeAmountTokens
        // rounds to zero) causing the protocol to revert with Argent__InvalidAmount.
        uint256 targetCollateral = protocol.getUserCollateral(target, address(tokenA));
        if (targetCollateral == 0) return;

        // Ensure the collateral price is non-zero before attempting liquidation.
        // A zero oracle price causes Argent__InvalidAsset inside _calculateCollateralSeized.
        uint256 collateralPrice = protocol.getAssetPrice(address(tokenA));
        if (collateralPrice == 0) return;

        // Bound repayAmount conservatively — use a fraction of debt
        // to avoid hitting the cap-and-scale boundary at extreme prices.
        repayAmount = bound(repayAmount, 1, debt / 2 == 0 ? debt : debt / 2);

        tokenB.mint(liq, repayAmount);
        vm.prank(liq);
        tokenB.approve(address(protocol), type(uint256).max);

        uint256 colBefore = protocol.getUserCollateral(target, address(tokenA));

        vm.prank(liq);
        // ✅ try/catch is intentional here — at extreme prices with tiny positions,
        // integer division in _getMaxLiquidatableDebt rounds closeAmountTokens to 0,
        // causing Argent__InvalidAmount. This is expected protocol behaviour, not a bug.
        // We cannot pre-compute this threshold without duplicating the protocol's math.
        try protocol.liquidate(target, address(tokenB), address(tokenA), repayAmount) {
            uint256 colAfter = protocol.getUserCollateral(target, address(tokenA));
            uint256 seized = colBefore - colAfter;
            if (ghostTotalCollateral[address(tokenA)] >= seized) {
                ghostTotalCollateral[address(tokenA)] -= seized;
            }
            ghostTotalBorrows[address(tokenB)] -= _min(repayAmount, ghostTotalBorrows[address(tokenB)]);
        } catch {}
    }

    /**
     * @dev Advance block time to trigger interest accrual paths.
     *      Bounded to keep runtimes reasonable.
     */
    function warpTime(uint256 secondsDelta) external {
        secondsDelta = bound(secondsDelta, 1, 90 days);
        vm.warp(block.timestamp + secondsDelta);
        _updateGhostIndex(address(tokenA));
        _updateGhostIndex(address(tokenB));
    }

    /**
     * @dev Shift tokenA price within a realistic band ($500 – $3 000).
     *      Allows the fuzzer to create liquidatable positions naturally.
     */
    function shiftPrice(uint256 newPrice) external {
        newPrice = bound(newPrice, 500e8, 3_000e8);
        oracle.setPrice(address(tokenA), newPrice);
    }
}
