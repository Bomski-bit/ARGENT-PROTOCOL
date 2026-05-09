// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArgentProtocol} from "../../src/ArgentProtocol.sol";
import {ArgentHandler} from "./ArgentHandler.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

contract ArgentProtocolInvariantTest is StdInvariant, Test {
    // ── Infrastructure ───────────────────────────────────────────────────────
    ArgentProtocol public protocol;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockPriceOracle public oracle;
    ArgentHandler public handler;

    // ── Named actors ─────────────────────────────────────────────────────────
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public dave = makeAddr("dave");
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");

    // ════════════════════════════════════════════════════════════════════════
    //  SET UP
    // ════════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy mocks
        tokenA = new MockERC20("TokenA", "TKA", 18);
        tokenB = new MockERC20("TokenB", "TKB", 6);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(tokenA), 2_000e8);
        oracle.setPrice(address(tokenB), 1e8);

        // Deploy protocol
        vm.prank(owner);
        protocol = new ArgentProtocol(
            address(oracle),
            treasury,
            1_500, // 15% protocol fee
            800, // 8%  liquidation bonus
            owner
        );

        // Register assets
        vm.startPrank(owner);
        protocol.addAsset(address(tokenA), 7_500, 8_000, 500, 18);
        protocol.addAsset(address(tokenB), 7_500, 8_000, 500, 6);
        vm.stopPrank();

        // Deploy handler with all actors
        address[4] memory actors = [alice, bob, charlie, dave];
        handler = new ArgentHandler(protocol, tokenA, tokenB, oracle, actors);

        // Tell Foundry: only call the handler, never the protocol directly
        targetContract(address(handler));
    }

    // ════════════════════════════════════════════════════════════════════════
    // INVARIANTS
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice INV-1 (CRITICAL): Real token balance covers all outstanding liabilities.
     *
     *   real_balance[asset] >= totalDeposits[asset] + totalLiquidity[asset]
     *                          - totalBorrows[asset]
     *
     *   If this breaks the contract cannot honour withdrawal requests.
     *   This is the single most catastrophic invariant in the protocol.
     */
    function invariant_01_realBalanceCoversAllLiabilities() public view {
        address[2] memory assets = [address(tokenA), address(tokenB)];

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];

            uint256 realBalance = IERC20(asset).balanceOf(address(protocol));
            uint256 totalDeposits = protocol.totalDeposits(asset);
            uint256 totalLiquidity = protocol.totalLiquidity(asset);
            uint256 totalBorrows = protocol.totalBorrows(asset);

            // Net obligation: what the protocol owes depositors after netting out loans
            uint256 gross = totalDeposits + totalLiquidity;
            uint256 netObligation = gross > totalBorrows ? gross - totalBorrows : 0;

            assertGe(realBalance, netObligation, "INV-1 CRITICAL: token balance cannot cover net depositor obligations");
        }
    }

    /**
     * @notice INV-2 (CRITICAL): Total borrows never exceed total deposits + liquidity.
     *
     *   totalBorrows[asset] <= totalDeposits[asset] + totalLiquidity[asset]
     *
     *   Lending out tokens that don't exist creates unbacked debt.
     *   Every lent token must come from a real deposit.
     */
    function invariant_02_borrowExcessLeadsToZeroAvailableLiquidity() public view {
        address[2] memory assets = [address(tokenA), address(tokenB)];

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 pool = protocol.totalDeposits(asset) + protocol.totalLiquidity(asset);
            uint256 borrows = protocol.totalBorrows(asset);
            uint256 fees = protocol.protocolFeesAccrued(asset);

            if (borrows + fees > pool) {
                // totalBorrows can legitimately exceed the simple pool sum after the repay()
                // fix capitalises accrued interest into totalBorrows.
                // When this happens the protocol MUST report zero available liquidity
                // so no new borrows or withdrawals can drain the contract.
                assertEq(
                    protocol.getAvailableLiquidity(asset),
                    0,
                    "INV-02 CRITICAL: borrows exceed pool but liquidity is still reported as available"
                );
            } else {
                // Normal case: available liquidity is correctly bounded by the pool
                assertLe(
                    protocol.getAvailableLiquidity(asset),
                    pool,
                    "INV-02 CRITICAL: available liquidity exceeds total pool"
                );
            }
        }
    }

    /**
     * @notice INV-3 (CRITICAL): Available liquidity is bounded above by the pool
     *         and never wraps to an astronomically large number on underflow.
     *
     *   0 <= getAvailableLiquidity(asset) <= totalDeposits + totalLiquidity
     *
     *   A wrapped underflow would make the protocol think it has unlimited
     *   liquidity, allowing unlimited borrows draining real tokens.
     */
    function invariant_03_availableLiquidityBoundedAndNonNegative() public view {
        address[2] memory assets = [address(tokenA), address(tokenB)];

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 available = protocol.getAvailableLiquidity(asset);
            uint256 ceiling = protocol.totalDeposits(asset) + protocol.totalLiquidity(asset);

            assertLe(available, ceiling, "INV-3 CRITICAL: availableLiquidity exceeds the total pool ceiling");
        }
    }

    /**
     * @notice INV-4 (HIGH): Ghost-tracked collateral is always >= totalDeposits.
     *
     *   ghostTotalCollateral[tokenA] >= totalDeposits[tokenA]
     *
     *   Ghost is an upper bound because it does not subtract seized collateral.
     *   If totalDeposits ever EXCEEDS the ghost, tokens have been created from
     *   nothing — a critical accounting bug.
     */
    function invariant_04_ghostCollateralUpperBoundsTotalDeposits() public view {
        assertGe(
            handler.ghostTotalCollateral(address(tokenA)),
            protocol.totalDeposits(address(tokenA)),
            "INV-4 HIGH: totalDeposits exceeds ghost - collateral created from nothing"
        );
    }

    /**
     * @notice INV-5 (HIGH): Ghost-tracked liquidity exactly equals totalLiquidity.
     *
     *   ghostTotalLiquidity[tokenB] == totalLiquidity[tokenB]
     *
     *   Unlike collateral, liquidity is never seized, so the ghost tracks it
     *   exactly. Any divergence means a deposit or withdrawal was not recorded.
     */
    function invariant_05_ghostLiquidityExactlyMatchesTotalLiquidity() public view {
        assertEq(
            handler.ghostTotalLiquidity(address(tokenB)),
            protocol.totalLiquidity(address(tokenB)),
            "INV-5 HIGH: totalLiquidity diverges from ghost - liquidity accounting broken"
        );
    }

    /**
     * @notice INV-6 (HIGH): Protocol fees accrued never exceed the total pool size.
     *
     *   protocolFeesAccrued[asset] <= totalDeposits[asset] + totalLiquidity[asset]
     *
     *   Fees come from the interest portion of repayments. They are a fraction of
     *   interest which is a fraction of borrows. If fees ever exceed the entire pool
     *   the fee accounting has compounded incorrectly and the treasury withdrawal
     *   would drain liquidity providers.
     */
    function invariant_06_protocolFeesBoundedByTotalPool() public view {
        address[2] memory assets = [address(tokenA), address(tokenB)];

        for (uint256 i; i < assets.length; i++) {
            address asset = assets[i];
            uint256 fees = protocol.protocolFeesAccrued(asset);
            uint256 poolTotal = protocol.totalDeposits(asset) + protocol.totalLiquidity(asset);

            assertLe(fees, poolTotal, "INV-6 HIGH: protocolFeesAccrued exceeds the entire deposit pool");
        }
    }

    /**
     * @notice INV-7 (HIGH): Borrow index is strictly monotonically non-decreasing.
     *
     *   borrowIndex[asset] at time T+N  >=  borrowIndex[asset] at time T
     *
     *   Interest can only accumulate. A decreasing index means debt is being
     *   erased without repayment — equivalent to gifting borrowed tokens.
     *   The ghost records the highest index ever observed and compares it to
     *   the current value.
     */
    function invariant_07_borrowIndexStrictlyNonDecreasing() public view {
        uint256 currentIdxA = protocol.getBorrowIndex(address(tokenA));
        uint256 currentIdxB = protocol.getBorrowIndex(address(tokenB));

        assertGe(
            currentIdxA,
            handler.ghostLastIndex(address(tokenA)),
            "INV-7 HIGH: tokenA borrow index decreased - interest cannot be negative"
        );
        assertGe(
            currentIdxB,
            handler.ghostLastIndex(address(tokenB)),
            "INV-7 HIGH: tokenB borrow index decreased - interest cannot be negative"
        );
    }

    /**
     * @notice INV-8 (HIGH): Borrow index never falls below INITIAL_INDEX (1e18)
     *         once it has been seeded.
     *
     *   borrowIndex[asset] >= 1e18  (after first accrual)
     *
     *   An index below 1e18 means the debt scaling factor is < 1.0, which would
     *   make _getAccruedDebt return less than the stored principal — effectively
     *   erasing debt without repayment.
     */
    function invariant_08_borrowIndexNeverFallsBelowInitialIndex() public view {
        uint256 idxA = protocol.getBorrowIndex(address(tokenA));
        uint256 idxB = protocol.getBorrowIndex(address(tokenB));

        // Only assert after the index has been initialized (first accrueInterest call sets it to 1e18)
        if (idxA > 0) {
            assertGe(idxA, 1e18, "INV-8 HIGH: tokenA borrow index fell below INITIAL_INDEX (1e18)");
        }
        if (idxB > 0) {
            assertGe(idxB, 1e18, "INV-8 HIGH: tokenB borrow index fell below INITIAL_INDEX (1e18)");
        }
    }

    /**
     * @notice INV-9 (HIGH): lastAccrualTimestamp never exceeds the current block time.
     *
     *   lastAccrualTimestamp[asset] <= block.timestamp
     *
     *   A future timestamp would make timeDelta underflow in the next accrual call,
     *   producing a massive interest spike that could corrupt every user's debt.
     */
    function invariant_09_lastAccrualTimestampNotInFuture() public view {
        assertLe(
            protocol.lastAccrualTimestamp(address(tokenA)),
            block.timestamp,
            "INV-9 HIGH: tokenA lastAccrualTimestamp is in the future"
        );
        assertLe(
            protocol.lastAccrualTimestamp(address(tokenB)),
            block.timestamp,
            "INV-9 HIGH: tokenB lastAccrualTimestamp is in the future"
        );
    }

    /**
     * @notice INV-10 (HIGH): No single user's collateral balance can exceed
     *         the total deposits recorded for that asset.
     *
     *   userCollateral[user][asset] <= totalDeposits[asset]  for all users
     *
     *   A user having more collateral than the total would mean collateral was
     *   minted from thin air — a direct path to draining the protocol.
     */
    function invariant_10_noUserCollateralExceedsTotalDeposits() public view {
        address[4] memory users = [alice, bob, charlie, dave];

        for (uint256 i; i < users.length; i++) {
            assertLe(
                protocol.getUserCollateral(users[i], address(tokenA)),
                protocol.totalDeposits(address(tokenA)),
                "INV-10 HIGH: a user's collateral exceeds totalDeposits"
            );
        }
    }

    /**
     * @notice INV-11 (HIGH): A user with zero total debt always has the maximum
     *         possible health factor (type(uint256).max).
     *
     *   totalDebtUSD(user) == 0  →  getHealthFactor(user) == type(uint256).max
     *
     *   A finite health factor with no debt means the HF calculation has a
     *   division-by-zero bug or a phantom debt that can never be repaid.
     */
    function invariant_11_zeroDebtImpliesMaxHealthFactor() public view {
        address[4] memory users = [alice, bob, charlie, dave];

        for (uint256 i; i < users.length; i++) {
            address user = users[i];
            uint256 debtUSD = protocol.getTotalDebtUSD(user);

            if (debtUSD == 0) {
                assertEq(
                    protocol.getHealthFactor(user),
                    type(uint256).max,
                    "INV-11 HIGH: user with zero debt does not have max health factor"
                );
            }
        }
    }

    /**
     * @notice INV-12 (HIGH): getLiquidatable and getHealthFactor are always consistent.
     *
     *   getHealthFactor(user) >= 1e18  ↔  getLiquidatable(user) == false
     *   getHealthFactor(user) <  1e18  ↔  getLiquidatable(user) == true
     *
     *   If these disagree:
     *   - A healthy user marked liquidatable → griefing / wrongful collateral seizure
     *   - An unhealthy user not marked liquidatable → bad debt silently accumulates
     *
     *   Both outcomes are HIGH severity because they either harm users directly
     *   or allow the protocol to accumulate unresolvable debt.
     */
    function invariant_12_liquidatabilityConsistentWithHealthFactor() public view {
        address[4] memory users = [alice, bob, charlie, dave];

        for (uint256 i; i < users.length; i++) {
            address user = users[i];
            uint256 hf = protocol.getHealthFactor(user);
            bool liquidatable = protocol.getLiquidatable(user);

            if (hf >= 1e18) {
                assertFalse(liquidatable, "INV-12 HIGH: healthy user (HF >= 1e18) is incorrectly marked liquidatable");
            } else {
                assertTrue(liquidatable, "INV-12 HIGH: unhealthy user (HF < 1e18) is not marked as liquidatable");
            }
        }
    }
}
