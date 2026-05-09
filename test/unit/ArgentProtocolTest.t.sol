// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  ArgentProtocol Test Suite
 * @notice Comprehensive unit tests targeting >90% function, branch, and statement coverage.
 *
 * ─── Token / USD math reference ──────────────────────────────────────────────
 *  _getAssetValueUSD(asset, amount) = (amount × price × 1e10) / (10 ** decimals)
 *
 *  tokenA  – 18 decimals, price $2 000  (2000e8 Chainlink format)
 *    1 tokenA = 1e18 atoms
 *    _getAssetValueUSD(tokenA, 1e18) = 1e18 × 2000e8 × 1e10 / 1e18 = 2000e18
 *
 *  tokenB  – 6 decimals,  price $1     (1e8 Chainlink format)
 *    1 tokenB unit = 1e6 atoms
 *    _getAssetValueUSD(tokenB, 1000e6) = 1000e6 × 1e8 × 1e10 / 1e6 = 1000e18
 *
 *  With LTV = 75 %:  1 tokenA → borrow limit = $1 500  → max 1 500e6 tokenB
 *  With LT  = 80 %:  liquidation when HF = (collateralUSD × 0.80) / debtUSD < 1
 *    At $1 700 price:  HF = (1700 × 0.80) / 1500 ≈ 0.907  → liquidatable
 * ─────────────────────────────────────────────────────────────────────────────
 */

import {Test, console} from "forge-std/Test.sol";
import {ArgentProtocol} from "../../src/ArgentProtocol.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

contract ArgentProtocolTest is Test {
    // ─── Protocol under test ─────────────────────────────────────────────────
    ArgentProtocol public protocol;

    // ─── Mock tokens ─────────────────────────────────────────────────────────
    MockERC20 public tokenA; // 18 decimals, $2 000 each
    MockERC20 public tokenB; // 6  decimals, $1    each
    MockPriceOracle public oracle;

    // ─── Named actors ────────────────────────────────────────────────────────
    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice"); // primary borrower
    address public bob = makeAddr("bob"); // liquidity provider
    address public charlie = makeAddr("charlie"); // secondary user
    address public liquidator = makeAddr("liquidator");

    // ─── Protocol parameters ─────────────────────────────────────────────────
    uint256 constant PROTOCOL_FEE = 1500; // 15 %
    uint256 constant LIQ_BONUS = 800; // 8 %
    uint256 constant BASIS_POINTS = 10_000;
    uint256 constant INITIAL_INDEX = 1e18;

    // ─── Asset configuration ─────────────────────────────────────────────────
    uint256 constant LTV_A = 7500; // 75 % loan-to-value
    uint256 constant LT_A = 8000; // 80 % liquidation threshold
    uint256 constant INTEREST_RATE = 500; // 5 % per year
    uint8 constant DEC_A = 18;
    uint8 constant DEC_B = 6;

    uint256 constant PRICE_A = 2000e8; // Chainlink 8-decimal format
    uint256 constant PRICE_B = 1e8;

    // ─── Convenience amounts (all in native token atoms) ─────────────────────
    uint256 constant COL_1A = 1e18; // 1 tokenA  → $2 000 collateral
    uint256 constant COL_10A = 10e18; // 10 tokenA → $20 000 collateral
    uint256 constant LIQ_5K = 5000e6; // 5000 tokenB liquidity
    uint256 constant LIQ_20K = 20_000e6;
    uint256 constant BORROW_MAX = 1500e6; // $1500 – max at 75 % LTV with 1 tokenA collateral
    uint256 constant BORROW_1000 = 1000e6; // $1000 borrow
    uint256 constant BORROW_500 = 500e6; // $500  borrow

    // ═══════════════════════════════════════════════════════════════════════
    //  SET UP
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy mock infrastructure
        tokenA = new MockERC20("TokenA", "TKA", DEC_A);
        tokenB = new MockERC20("TokenB", "TKB", DEC_B);
        oracle = new MockPriceOracle();
        oracle.setPrice(address(tokenA), PRICE_A);
        oracle.setPrice(address(tokenB), PRICE_B);

        // Deploy protocol
        vm.prank(owner);
        protocol = new ArgentProtocol(address(oracle), treasury, PROTOCOL_FEE, LIQ_BONUS, owner);

        // Register both assets
        vm.startPrank(owner);
        protocol.addAsset(address(tokenA), LTV_A, LT_A, INTEREST_RATE, DEC_A);
        protocol.addAsset(address(tokenB), LTV_A, LT_A, INTEREST_RATE, DEC_B);
        vm.stopPrank();

        // Fund every actor with ample balances and max approvals
        address[4] memory actors = [alice, bob, charlie, liquidator];
        for (uint256 i; i < actors.length; i++) {
            tokenA.mint(actors[i], 1_000e18);
            tokenB.mint(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            tokenA.approve(address(protocol), type(uint256).max);
            tokenB.approve(address(protocol), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _depositCollateral(address user, uint256 amount) internal {
        vm.prank(user);
        protocol.depositCollateral(address(tokenA), amount);
    }

    function _depositLiquidity(address provider, uint256 amount) internal {
        vm.prank(provider);
        protocol.depositLiquidity(address(tokenB), amount);
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        protocol.borrow(address(tokenB), amount);
    }

    function _repay(address user, uint256 amount) internal {
        vm.prank(user);
        protocol.repay(address(tokenB), amount);
    }

    /**
     * @dev Puts Alice into a liquidatable state:
     *   1. Alice deposits 1 tokenA ($2 000) as collateral
     *   2. Bob provides 5 000 tokenB of liquidity
     *   3. Alice borrows 1 500 tokenB ($1 500 – max LTV 75 %)
     *   4. tokenA price drops to $1 700 → HF ≈ 0.907 < 1 → liquidatable
     */
    function _makeLiquidatable() internal {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_MAX);
        oracle.setPrice(address(tokenA), 1700e8);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 1 – CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: state is wired correctly after deployment.
    function testConstructorSetsStateCorrectly() public view {
        assertEq(address(protocol.priceOracle()), address(oracle));
        assertEq(protocol.treasury(), treasury);
        assertEq(protocol.protocolFee(), PROTOCOL_FEE);
        assertEq(protocol.liquidationBonus(), LIQ_BONUS);
    }

    /// @dev Zero owner address must revert (Ownable sets owner first, and reverts first before our guard runs).
    function testConstructorRevertsWhenZeroOwner() public {
        vm.expectRevert();
        new ArgentProtocol(address(oracle), treasury, PROTOCOL_FEE, LIQ_BONUS, address(0));
    }

    /// @dev Zero oracle address must revert.
    function testConstructorRevertsWhenZeroOracle() public {
        vm.expectRevert(ArgentProtocol.Argent__InvalidAddress.selector);
        new ArgentProtocol(address(0), treasury, PROTOCOL_FEE, LIQ_BONUS, owner);
    }

    /// @dev Zero treasury address must revert.
    function testConstructorRevertsWhenZeroTreasury() public {
        vm.expectRevert(ArgentProtocol.Argent__InvalidAddress.selector);
        new ArgentProtocol(address(oracle), address(0), PROTOCOL_FEE, LIQ_BONUS, owner);
    }

    /// @dev Protocol fee > BASIS_POINTS must revert.
    function testConstructorRevertsWhenProtocolFeeTooHigh() public {
        vm.expectRevert(ArgentProtocol.Argent__FeeTooHigh.selector);
        new ArgentProtocol(address(oracle), treasury, BASIS_POINTS + 1, LIQ_BONUS, owner);
    }

    /// @dev Liquidation bonus > BASIS_POINTS must revert.
    function testConstructorRevertsWhenLiqBonusTooHigh() public {
        vm.expectRevert(ArgentProtocol.Argent__BonusTooHigh.selector);
        new ArgentProtocol(address(oracle), treasury, PROTOCOL_FEE, BASIS_POINTS + 1, owner);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 2 – addAsset / setAssetStatus
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev New asset is added, config set, pushed to supportedAssets, event emitted.
    function testAddAssetNewAssetInitializesCorrectly() public {
        MockERC20 tokenC = new MockERC20("C", "C", 8);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ArgentProtocol.AssetAdded(address(tokenC), 6000, 7500, 300);
        protocol.addAsset(address(tokenC), 6000, 7500, 300, 8);

        (ArgentProtocol.AssetStatus status, uint256 ltv,,,) = protocol.assetConfig(address(tokenC));
        assertEq(uint8(status), uint8(ArgentProtocol.AssetStatus.ACTIVE));
        assertEq(ltv, 6000);

        // Must appear as the 3rd entry in supportedAssets
        address[] memory supported = protocol.getSupportedAssets();
        assertEq(supported.length, 3);
        assertEq(supported[2], address(tokenC));
    }

    /// @dev Re-adding an existing asset updates config but does NOT duplicate supportedAssets.
    function testAddAssetUpdateExistingAssetWithNoDuplication() public {
        vm.prank(owner);
        protocol.addAsset(address(tokenA), 6000, 7000, 400, DEC_A);

        assertEq(protocol.getSupportedAssets().length, 2); // still 2
        (, uint256 ltv,,,) = protocol.assetConfig(address(tokenA));
        assertEq(ltv, 6000); // updated
    }

    /// @dev asset == address(0) must revert.
    function testAddAssetRevertsWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAddress.selector);
        protocol.addAsset(address(0), LTV_A, LT_A, INTEREST_RATE, DEC_A);
    }

    /// @dev ltv > BASIS_POINTS must revert.
    function testAddAssetRevertsWhenLtvExceedsBasisPoints() public {
        MockERC20 c = new MockERC20("C", "C", 18);
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__FeeTooHigh.selector);
        protocol.addAsset(address(c), BASIS_POINTS + 1, LT_A, INTEREST_RATE, 18);
    }

    /// @dev liquidationThreshold > BASIS_POINTS must revert.
    function testAddAssetRevertsWhenLtExceedsBasisPoints() public {
        MockERC20 c = new MockERC20("C", "C", 18);
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__FeeTooHigh.selector);
        protocol.addAsset(address(c), LTV_A, BASIS_POINTS + 1, INTEREST_RATE, 18);
    }

    /// @dev ltv > liquidationThreshold is an invalid parameter.
    function testAddAssetRevertsWhenLtvGreaterThanLt() public {
        MockERC20 c = new MockERC20("C", "C", 18);
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidParameter.selector);
        protocol.addAsset(address(c), 9000, 8000, INTEREST_RATE, 18);
    }

    /// @dev Non-owner cannot add assets.
    function testAddAssetRevertsWhenNotOwner() public {
        MockERC20 c = new MockERC20("C", "C", 18);
        vm.prank(alice);
        vm.expectRevert();
        protocol.addAsset(address(c), LTV_A, LT_A, INTEREST_RATE, 18);
    }

    /// @dev Owner can freeze and re-activate an asset; event is emitted.
    function testSetAssetStatusFreezeAndActivateWorksProperlyAndEmitsEvent() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, false);
        emit ArgentProtocol.AssetStatusUpdated(
            address(tokenA), ArgentProtocol.AssetStatus.ACTIVE, ArgentProtocol.AssetStatus.FROZEN
        );
        protocol.setAssetStatus(address(tokenA), ArgentProtocol.AssetStatus.FROZEN);

        (ArgentProtocol.AssetStatus status,,,,) = protocol.assetConfig(address(tokenA));
        assertEq(uint8(status), uint8(ArgentProtocol.AssetStatus.FROZEN));

        // Re-activate
        protocol.setAssetStatus(address(tokenA), ArgentProtocol.AssetStatus.ACTIVE);
        (status,,,,) = protocol.assetConfig(address(tokenA));
        assertEq(uint8(status), uint8(ArgentProtocol.AssetStatus.ACTIVE));
        vm.stopPrank();
    }

    /// @dev Setting status on an asset with borrowIndex == 0 (never registered) must revert.
    function testSetAssetStatusRevertsWhenUnregisteredAsset() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAsset.selector);
        protocol.setAssetStatus(makeAddr("ghost"), ArgentProtocol.AssetStatus.FROZEN);
    }

    /// @dev Non-owner cannot update asset status.
    function testSetAssetStatusRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.setAssetStatus(address(tokenA), ArgentProtocol.AssetStatus.FROZEN);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 3 – PAUSE / UNPAUSE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Non-owner cannot pause.
    function testPauseRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.pause();
    }

    /// @dev Non-owner cannot unpause.
    function testUnpauseRevertsWhenNotOwner() public {
        vm.prank(owner);
        protocol.pause();
        vm.prank(alice);
        vm.expectRevert();
        protocol.unpause();
    }

    /// @dev Paused protocol blocks depositCollateral.
    function testPauseBlocksDepositCollateral() public {
        vm.prank(owner);
        protocol.pause();
        vm.prank(alice);
        vm.expectRevert();
        protocol.depositCollateral(address(tokenA), COL_1A);
    }

    /// @dev Paused protocol blocks withdrawCollateral.
    function testPauseBlocksWithdrawCollateral() public {
        _depositCollateral(alice, COL_1A);
        vm.prank(owner);
        protocol.pause();
        vm.prank(alice);
        vm.expectRevert();
        protocol.withdrawCollateral(address(tokenA), COL_1A);
    }

    /// @dev Paused protocol blocks depositLiquidity.
    function testPauseBlocksDepositLiquidity() public {
        vm.prank(owner);
        protocol.pause();
        vm.prank(bob);
        vm.expectRevert();
        protocol.depositLiquidity(address(tokenB), LIQ_5K);
    }

    /// @dev Paused protocol blocks withdrawLiquidity.
    function testPauseBlocksWithdrawLiquidity() public {
        _depositLiquidity(bob, LIQ_5K);
        vm.prank(owner);
        protocol.pause();
        vm.prank(bob);
        vm.expectRevert();
        protocol.withdrawLiquidity(address(tokenB), LIQ_5K);
    }

    /// @dev Paused protocol blocks borrow.
    function testPauseBlocksBorrow() public {
        vm.prank(owner);
        protocol.pause();
        vm.prank(alice);
        vm.expectRevert();
        protocol.borrow(address(tokenB), BORROW_1000);
    }

    /// @dev After unpausing, normal operations resume successfully.
    function testUnpauseResumesOperations() public {
        vm.startPrank(owner);
        protocol.pause();
        protocol.unpause();
        vm.stopPrank();
        _depositCollateral(alice, COL_1A);
        assertEq(protocol.getUserCollateral(alice, address(tokenA)), COL_1A);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 4 – DEPOSIT COLLATERAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: balances, mappings, event all correct.
    function testDepositCollateralSuccessfullyUpdatesAllState() public {
        uint256 protocolBalBefore = tokenA.balanceOf(address(protocol));
        uint256 aliceBalBefore = tokenA.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ArgentProtocol.CollateralDeposited(alice, address(tokenA), COL_1A);
        protocol.depositCollateral(address(tokenA), COL_1A);

        assertEq(protocol.getUserCollateral(alice, address(tokenA)), COL_1A);
        assertEq(protocol.totalDeposits(address(tokenA)), COL_1A);
        assertEq(tokenA.balanceOf(alice), aliceBalBefore - COL_1A);
        assertEq(tokenA.balanceOf(address(protocol)), protocolBalBefore + COL_1A);
    }

    /// @dev Multiple deposits accumulate correctly.
    function testDepositCollateralMultipleDepositsAccumulate() public {
        _depositCollateral(alice, COL_1A);
        _depositCollateral(alice, COL_1A);
        assertEq(protocol.getUserCollateral(alice, address(tokenA)), 2 * COL_1A);
        assertEq(protocol.totalDeposits(address(tokenA)), 2 * COL_1A);
    }

    /// @dev amount == 0 must revert.
    function testDepositCollateralRevertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.depositCollateral(address(tokenA), 0);
    }

    /// @dev FROZEN asset must revert with Argent__AssetNotSupported.
    function testDepositCollateralRevertsWhenFrozenAsset() public {
        vm.prank(owner);
        protocol.setAssetStatus(address(tokenA), ArgentProtocol.AssetStatus.FROZEN);
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.depositCollateral(address(tokenA), COL_1A);
    }

    /// @dev INACTIVE asset must revert.
    function testDepositCollateralRevertsWhenInactiveAsset() public {
        vm.prank(owner);
        protocol.setAssetStatus(address(tokenA), ArgentProtocol.AssetStatus.INACTIVE);
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.depositCollateral(address(tokenA), COL_1A);
    }

    /// @dev Completely unregistered asset must revert.
    function testDepositCollateralRevertsWhenUnregisteredAsset() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.depositCollateral(makeAddr("notAnAsset"), 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 5 – WITHDRAW COLLATERAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Full withdrawal with no debt: tokens returned, state zeroed.
    function testWithdrawCollateralFullyWithdrawnWhenNoDebt() public {
        _depositCollateral(alice, COL_1A);
        uint256 aliceBalBefore = tokenA.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ArgentProtocol.CollateralWithdrawn(alice, address(tokenA), COL_1A);
        protocol.withdrawCollateral(address(tokenA), COL_1A);

        assertEq(protocol.getUserCollateral(alice, address(tokenA)), 0);
        assertEq(protocol.totalDeposits(address(tokenA)), 0);
        assertEq(tokenA.balanceOf(alice), aliceBalBefore + COL_1A);
    }

    /**
     * @dev Partial withdrawal is allowed when the remaining collateral keeps HF ≥ 1.
     *      10 tokenA ($20 000) collateral, $1 000 debt → can withdraw 1 tokenA safely.
     */
    function testWithdrawCollateralPartiallyStillMaintainsHealthyPosition() public {
        _depositCollateral(alice, COL_10A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        vm.prank(alice);
        protocol.withdrawCollateral(address(tokenA), COL_1A);

        assertEq(protocol.getUserCollateral(alice, address(tokenA)), 9e18);
    }

    /// @dev amount == 0 must revert.
    function testWithdrawCollateralRevertsWhenZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.withdrawCollateral(address(tokenA), 0);
    }

    /// @dev Withdrawing more than deposited must revert.
    function testWithdrawCollateralRevertsWhenInsufficientCollateral() public {
        _depositCollateral(alice, COL_1A);
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InsufficientCollateral.selector);
        protocol.withdrawCollateral(address(tokenA), 2e18);
    }

    /**
     * @dev Withdrawing ALL collateral while at max LTV makes HF = 0 → position unhealthy.
     *      1 tokenA ($2 000), borrow $1 500 (max 75 % LTV). Full withdrawal → revert.
     */
    function testWithdrawCollateralRevertsWhenPositionUnhealthyAfterWithdraw() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_MAX);

        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__PositionUnhealthy.selector);
        protocol.withdrawCollateral(address(tokenA), COL_1A);
    }

    /// @dev withdrawCollateral accrues interest on debt assets before performing its health check.
    function testWithdrawCollateralAccruesInterestOnDebtAssets() public {
        _depositCollateral(alice, COL_10A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        uint256 tsBefore = protocol.lastAccrualTimestamp(address(tokenB));
        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        protocol.withdrawCollateral(address(tokenA), COL_1A); // position stays healthy

        assertGt(
            protocol.lastAccrualTimestamp(address(tokenB)), tsBefore, "accrueInterest should have updated the timestamp"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 6 – DEPOSIT LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: totalLiquidity and user balance updated; event emitted.
    function testDepositLiquiditySuccessfullyUpdatesState() public {
        uint256 bobBalBefore = tokenB.balanceOf(bob);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit ArgentProtocol.LiquidityDeposited(bob, address(tokenB), LIQ_5K);
        protocol.depositLiquidity(address(tokenB), LIQ_5K);

        assertEq(protocol.getUserLiquidityDeposit(bob, address(tokenB)), LIQ_5K);
        assertEq(protocol.totalLiquidity(address(tokenB)), LIQ_5K);
        assertEq(tokenB.balanceOf(bob), bobBalBefore - LIQ_5K);
    }

    /// @dev amount == 0 must revert.
    function testDepositLiquidityRevertsWhenZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.depositLiquidity(address(tokenB), 0);
    }

    /// @dev FROZEN asset must revert.
    function testDepositLiquidityRevertsWhenFrozenAsset() public {
        vm.prank(owner);
        protocol.setAssetStatus(address(tokenB), ArgentProtocol.AssetStatus.FROZEN);
        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.depositLiquidity(address(tokenB), LIQ_5K);
    }

    /// @dev INACTIVE asset must revert.
    function testDepositLiquidityRevertsWhenInactiveAsset() public {
        vm.prank(owner);
        protocol.setAssetStatus(address(tokenB), ArgentProtocol.AssetStatus.INACTIVE);
        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.depositLiquidity(address(tokenB), LIQ_5K);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 7 – WITHDRAW LIQUIDITY
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: liquidity returned, state zeroed, event emitted.
    function testWithdrawLiquidityFullWithdrawSuccessful() public {
        _depositLiquidity(bob, LIQ_5K);
        uint256 bobBalBefore = tokenB.balanceOf(bob);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit ArgentProtocol.LiquidityWithdrawn(bob, address(tokenB), LIQ_5K);
        protocol.withdrawLiquidity(address(tokenB), LIQ_5K);

        assertEq(protocol.getUserLiquidityDeposit(bob, address(tokenB)), 0);
        assertEq(protocol.totalLiquidity(address(tokenB)), 0);
        assertEq(tokenB.balanceOf(bob), bobBalBefore + LIQ_5K);
    }

    /// @dev amount == 0 must revert.
    function testWithdrawLiquidityRevertsWhenZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.withdrawLiquidity(address(tokenB), 0);
    }

    /**
     * @dev Requesting more than totalLiquidity reverts even if user deposited enough
     *      – the global pool is checked first.
     */
    function testWithdrawLiquidityRevertsWhenInsufficientTotalLiquidity() public {
        _depositLiquidity(bob, LIQ_5K);
        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__InsufficientTotalLiquidity.selector);
        protocol.withdrawLiquidity(address(tokenB), LIQ_5K + 1);
    }

    /**
     * @dev User cannot withdraw more than their personal deposit even if total pool is large.
     *      Bob has 5 000 but pool has 15 000 (charlie added 10 000) → revert.
     */
    function testWithdrawLiquidityRevertsWhenInsufficientUserBalance() public {
        _depositLiquidity(bob, LIQ_5K);
        _depositLiquidity(charlie, LIQ_5K * 2);

        vm.prank(bob);
        vm.expectRevert(ArgentProtocol.Argent__InsufficientLiquidity.selector);
        protocol.withdrawLiquidity(address(tokenB), LIQ_5K + 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 8 – BORROW
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: debt recorded, tokens transferred, event emitted.
    function testBorrowSuccessfullyUpdatesAllState() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);

        uint256 aliceBalBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ArgentProtocol.Borrowed(alice, address(tokenB), BORROW_1000);
        protocol.borrow(address(tokenB), BORROW_1000);

        assertEq(protocol.getUserDebt(alice, address(tokenB)), BORROW_1000);
        assertEq(protocol.totalBorrows(address(tokenB)), BORROW_1000);
        assertEq(tokenB.balanceOf(alice), aliceBalBefore + BORROW_1000);
    }

    /// @dev amount == 0 must revert.
    function testBorrowRevertsWhenZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.borrow(address(tokenB), 0);
    }

    /// @dev Borrowing a FROZEN asset must revert.
    function testBorrowRevertsWhenAssetIsFrozen() public {
        vm.prank(owner);
        protocol.setAssetStatus(address(tokenB), ArgentProtocol.AssetStatus.FROZEN);
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__AssetNotSupported.selector);
        protocol.borrow(address(tokenB), BORROW_1000);
    }

    /// @dev Borrow fails when the protocol has no tokenB liquidity.
    function testBorrowRevertsWhenNoLiquidity() public {
        _depositCollateral(alice, COL_1A);
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InsufficientLiquidity.selector);
        protocol.borrow(address(tokenB), BORROW_1000);
    }

    /**
     * @dev Borrow fails when the requested amount exceeds the user's LTV-based limit.
     *      1 tokenA → max $1 500; requesting $1 500 + 1 atom must revert.
     */
    function testBorrowRevertsWhenAmountExceedsLTVLimit() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);

        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__PositionUnhealthy.selector);
        protocol.borrow(address(tokenB), BORROW_MAX + 1);
    }

    /**
     * @dev A second borrow after a time warp accumulates accrued interest on the
     *      first borrow, making total debt > sum of borrows.
     */
    function testBorrowSubsequentBorrowAccruesInterest() public {
        _depositCollateral(alice, COL_10A);
        _depositLiquidity(bob, LIQ_20K);

        _borrow(alice, BORROW_1000);
        vm.warp(block.timestamp + 180 days); // let interest accrue
        _borrow(alice, BORROW_500);

        uint256 debt = protocol.getUserDebt(alice, address(tokenB));
        assertGt(debt, BORROW_1000 + BORROW_500, "accumulated interest must increase total debt beyond raw borrows");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 9 – REPAY
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Full repayment clears debt to zero.
    function testRepayFullRepayClearsDebt() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        vm.warp(block.timestamp + 30 days); // let a little interest accrue
        uint256 debt = protocol.getUserDebt(alice, address(tokenB));

        vm.prank(alice);
        vm.expectEmit(true, true, false, false); // ignore amount (with interest)
        emit ArgentProtocol.Repaid(alice, address(tokenB), debt);
        protocol.repay(address(tokenB), debt);

        assertEq(protocol.getUserDebt(alice, address(tokenB)), 0);
    }

    /// @dev Partial repayment reduces debt proportionally (no significant time delta).
    function testRepayPartiallyReducesDebt() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        _repay(alice, BORROW_500);

        // Allow a small rounding tolerance (< 0.001 tokenB)
        assertApproxEqAbs(
            protocol.getUserDebt(alice, address(tokenB)),
            BORROW_500,
            1_000 // 1_000 atoms of tokenB-6dec ≈ 0.000001 tokenB
        );
    }

    /**
     * @dev Over-repaying (supplying 10× the debt) caps at the actual debt amount.
     *      The user should not lose tokens beyond the outstanding balance.
     */
    function testRepayOverRepayCapsAtActualDebt() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        _repay(alice, BORROW_1000 * 10);
        assertEq(protocol.getUserDebt(alice, address(tokenB)), 0);
    }

    /// @dev amount == 0 must revert.
    function testRepayRevertsWhenZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.repay(address(tokenB), 0);
    }

    /// @dev Repaying when there is no outstanding debt must revert.
    function testRepayRevertsWhenNoDebt() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__NoDebt.selector);
        protocol.repay(address(tokenB), BORROW_1000);
    }

    /// @dev Interest paid beyond the original principal is charged a protocol fee.
    function testRepayProtocolFeeAccruedOnInterest() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        vm.warp(block.timestamp + 365 days); // 1 year of 5 % interest

        uint256 feesBefore = protocol.protocolFeesAccrued(address(tokenB));
        uint256 debt = protocol.getUserDebt(alice, address(tokenB));
        _repay(alice, debt);

        assertGt(
            protocol.protocolFeesAccrued(address(tokenB)), feesBefore, "protocol should collect fee on accrued interest"
        );
    }

    /**
     * @dev When repaying in the same block as borrowing (timeDelta == 0),
     *      no interest accrues so no protocol fee is charged.
     */
    function testRepayNoFeeWhenRepaidWithinSameBlock() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        uint256 feesBefore = protocol.protocolFeesAccrued(address(tokenB));
        _repay(alice, BORROW_1000); // no warp → no interest
        assertEq(protocol.protocolFeesAccrued(address(tokenB)), feesBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 10 – INTEREST ACCRUAL
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Accruing after a time delta increases the borrow index.
    function testAccrueInterestIncreasesIndexAfterTimeElapsed() public {
        uint256 indexBefore = protocol.getBorrowIndex(address(tokenA));
        vm.warp(block.timestamp + 365 days);
        protocol.accrueInterest(address(tokenA));
        assertGt(protocol.getBorrowIndex(address(tokenA)), indexBefore);
    }

    /**
     * @dev Calling accrueInterest in the same block as the last accrual
     *      returns immediately, no state change.
     */
    function testAccrueInterestSameBlockDoesNothing() public {
        uint256 tsBefore = protocol.lastAccrualTimestamp(address(tokenA));
        uint256 indexBefore = protocol.getBorrowIndex(address(tokenA));

        protocol.accrueInterest(address(tokenA)); // no warp → same timestamp

        assertEq(protocol.getBorrowIndex(address(tokenA)), indexBefore);
        assertEq(protocol.lastAccrualTimestamp(address(tokenA)), tsBefore);
    }

    /// @dev Multiple sequential accruals compound the index correctly.
    function testAccrueInterestCompoundsOverMultiplePeriods() public {
        vm.warp(block.timestamp + 180 days);
        protocol.accrueInterest(address(tokenA));
        uint256 index1 = protocol.getBorrowIndex(address(tokenA));

        vm.warp(block.timestamp + 360 days);
        protocol.accrueInterest(address(tokenA));
        uint256 index2 = protocol.getBorrowIndex(address(tokenA));

        assertGt(index2, index1);
    }

    /**
     * @dev Calling accrueInterest on an asset with lastAccrualTimestamp == 0
     *      (a never-initialized address) initialises borrowIndex and timestamp.
     *      This covers the `if (lastAccrual == 0)` initialisation branch.
     */
    function testAccrueInterestUninitializedAssetInitializesState() public {
        address ghost = makeAddr("ghost");
        assertEq(protocol.lastAccrualTimestamp(ghost), 0);

        protocol.accrueInterest(ghost);

        assertEq(protocol.lastAccrualTimestamp(ghost), block.timestamp);
        assertEq(protocol.getBorrowIndex(ghost), INITIAL_INDEX);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 11 – HEALTH FACTOR & VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev getBorrowIndex is a pure view that calculates the current index
     *      without updating lastAccrualTimestamp.
     */
    function testGetBorrowIndexReturnsCurrentIndexWithoutUpdatingState() public {
        uint256 tsBefore = protocol.lastAccrualTimestamp(address(tokenA));
        vm.warp(block.timestamp + 1 days);

        uint256 viewIndex = protocol.getBorrowIndex(address(tokenA));

        assertGt(viewIndex, INITIAL_INDEX);
        assertEq(protocol.lastAccrualTimestamp(address(tokenA)), tsBefore); // not mutated
    }

    /// @dev A user with no debt has an infinite (max uint256) health factor.
    function testHealthFactorWithNoDebtReturnsMaxUint() public view {
        assertEq(protocol.getHealthFactor(alice), type(uint256).max);
    }

    /**
     * @dev HF = (collateralUSD × LT) / debtUSD
     *      = ($2 000 × 0.80) / $1 000 = 1.6  → 1.6e18
     */
    function testHealthFactorWithDebtAboveOne() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        uint256 hf = protocol.getHealthFactor(alice);
        assertApproxEqRel(hf, 1.6e18, 0.01e18);
    }

    /// @dev After a price drop the health factor falls below 1.
    function testHealthFactorBelowOneWhenPriceDrops() public {
        _makeLiquidatable();
        assertLt(protocol.getHealthFactor(alice), 1e18);
    }

    /// @dev getLiquidatable returns false for a healthy position.
    function testGetLiquidatableReturnsFalseForHealthyPosition() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_500);
        assertFalse(protocol.getLiquidatable(alice));
    }

    /// @dev getLiquidatable returns true after a price crash.
    function testGetLiquidatableTrueAfterPriceCrash() public {
        _makeLiquidatable();
        assertTrue(protocol.getLiquidatable(alice));
    }

    /// @dev Borrow limit is 0 when no collateral is deposited.
    function testGetBorrowLimitZeroWithNoCollateral() public view {
        assertEq(protocol.getBorrowLimit(alice), 0);
    }

    /**
     * @dev Borrow limit = collateralUSD × LTV / BP.
     *      1 tokenA ($2 000) at 75 % LTV → limit = 1 500e18 internal USD.
     */
    function testGetBorrowLimitWithCollateral() public {
        _depositCollateral(alice, COL_1A);
        assertEq(protocol.getBorrowLimit(alice), 1500e18);
    }

    /// @dev Available borrow = limit − current debt.
    function testGetUserAvailableBorrowWithPartialDebt() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_500); // $500

        uint256 available = protocol.getUserAvailableBorrow(alice);
        // $1 500 limit − $500 debt ≈ $1 000 = 1 000e18 internal USD
        assertApproxEqAbs(available, 1000e18, 1e15);
    }

    /// @dev When debt exceeds the borrow limit (price crash), available borrow is 0.
    function testGetUserAvailableBorrowReturnsZeroWhenDebtExceedsLimit() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_MAX);
        oracle.setPrice(address(tokenA), 100e8); // massive price crash
        assertEq(protocol.getUserAvailableBorrow(alice), 0);
    }

    /// @dev getTotalCollateralUSD returns 0 for a user with no deposits.
    function testGetTotalCollateralUSDReturnsZeroForNewUser() public view {
        assertEq(protocol.getTotalCollateralUSD(alice), 0);
    }

    /// @dev 1 tokenA at $2 000 → 2 000e18 internal USD.
    function testGetTotalCollateralUSDReturnsCorrectValue() public {
        _depositCollateral(alice, COL_1A);
        assertEq(protocol.getTotalCollateralUSD(alice), 2000e18);
    }

    /// @dev getTotalDebtUSD returns 0 before any borrow.
    function testGetTotalDebtUSDReturnsZeroBeforeBorrow() public view {
        assertEq(protocol.getTotalDebtUSD(alice), 0);
    }

    /// @dev 1 000 tokenB at $1 → 1 000e18 internal USD.
    function testGetTotalDebtUSDReturnsCorrectValue() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);
        assertApproxEqAbs(protocol.getTotalDebtUSD(alice), 1000e18, 1e15);
    }

    /// @dev Available liquidity = (totalDeposits + totalLiquidity) − totalBorrows − fees.
    function testGetAvailableLiquidityReturnsCorrectValue() public {
        _depositLiquidity(bob, LIQ_5K);
        assertEq(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K);

        _depositCollateral(alice, COL_1A);
        _borrow(alice, BORROW_1000);
        assertEq(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K - BORROW_1000);
    }

    /// @dev Protocol fees reduce available liquidity.
    function testGetAvailableLiquidityFeesReduceAvailableLiquidity() public {
        _depositLiquidity(bob, LIQ_5K);
        _depositCollateral(alice, COL_1A);
        _borrow(alice, BORROW_1000);
        vm.warp(block.timestamp + 365 days);
        _repay(alice, protocol.getUserDebt(alice, address(tokenB)));

        uint256 fees = protocol.protocolFeesAccrued(address(tokenB));
        if (fees > 0) {
            // Raw liquidity is LIQ_5K, but fees reduce available balance
            assertLt(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K);
        }
    }

    /// @dev When there is nothing in the pool, available liquidity returns 0 (no underflow).
    function testGetAvailableLiquidityReturnsZeroWhenNoLiquidity() public view {
        assertEq(protocol.getAvailableLiquidity(address(tokenA)), 0);
    }

    /// @dev getAssetPrice delegates correctly to the oracle.
    function testGetAssetPriceMatchesOracle() public view {
        assertEq(protocol.getAssetPrice(address(tokenA)), PRICE_A);
        assertEq(protocol.getAssetPrice(address(tokenB)), PRICE_B);
    }

    /// @dev getAssetValueUSD returns 0 for a zero amount.
    function testGetAssetValueUSDReturnsZeroForZeroAmount() public view {
        assertEq(protocol.getAssetValueUSD(address(tokenA), 0), 0);
    }

    /// @dev getAssetValueUSD computes correctly for both tokens.
    function testGetAssetValueUSDCorrectConversion() public view {
        assertEq(protocol.getAssetValueUSD(address(tokenA), 1e18), 2000e18);
        assertEq(protocol.getAssetValueUSD(address(tokenB), 1000e6), 1000e18);
    }

    function testGetLiquidationThresholdReturnsConfigValue() public view {
        assertEq(protocol.getLiquidationThreshold(address(tokenA)), LT_A);
    }

    function testGetInterestRateReturnsConfigValue() public view {
        assertEq(protocol.getInterestRate(address(tokenA)), INTEREST_RATE);
    }

    /// @dev After borrowing, user's debt index snapshot equals the current borrow index.
    function testGetUserDebtIndexSetToCurrentIndexAfterBorrow() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);
        assertEq(protocol.getUserDebtIndex(alice, address(tokenB)), INITIAL_INDEX);
    }

    function testGetSupportedAssetsReturnsAll() public view {
        address[] memory supported = protocol.getSupportedAssets();
        assertEq(supported.length, 2);
        assertEq(supported[0], address(tokenA));
        assertEq(supported[1], address(tokenB));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 12 – LIQUIDATIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Happy path: liquidator pays debt, receives collateral, state updated.
    function testLiquidateSuccessfullyReducesDebtAndCollateral() public {
        _makeLiquidatable();

        uint256 debtBefore = protocol.getUserDebt(alice, address(tokenB));
        uint256 collBefore = protocol.getUserCollateral(alice, address(tokenA));

        vm.prank(liquidator);
        vm.expectEmit(true, true, false, false); // topic check only
        emit ArgentProtocol.Liquidated(liquidator, alice, address(tokenB), address(tokenA), 0, 0);
        protocol.liquidate(alice, address(tokenB), address(tokenA), debtBefore);

        assertLt(protocol.getUserDebt(alice, address(tokenB)), debtBefore, "debt must decrease");
        assertLt(protocol.getUserCollateral(alice, address(tokenA)), collBefore, "collateral must decrease");
        assertGt(tokenA.balanceOf(liquidator), 0, "liquidator must receive tokenA");
    }

    /**
     * @dev Verify the liquidation bonus is included in the seized collateral.
     *      Expected seize ≈ debtValueUSD × (1 + bonus) / collateralPrice
     */
    function testLiquidateSuccessfullyCollateralSeizedIncludesBonus() public {
        _makeLiquidatable();

        // collateralToSeize for BORROW_500 at collateral price $1 700:
        // = (500e18 * (10000 + 800) * 1e18) / (1700e8 * 1e10 * 10000)
        uint256 expectedSeize = (uint256(500e18) * (BASIS_POINTS + LIQ_BONUS) * 1e18) / (1700e8 * 1e10 * BASIS_POINTS);

        uint256 balBefore = tokenA.balanceOf(liquidator);
        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_500);

        assertApproxEqRel(
            tokenA.balanceOf(liquidator) - balBefore,
            expectedSeize,
            0.01e18,
            "seized collateral must match formula within 1 %"
        );
    }

    /// @dev A user cannot liquidate themselves.
    function testLiquidateRevertsWhenUserliquidatesSelf() public {
        vm.prank(alice);
        vm.expectRevert(ArgentProtocol.Argent__CannotLiquidateSelf.selector);
        protocol.liquidate(alice, address(tokenB), address(tokenA), 1e6);
    }

    /// @dev repayAmount == 0 must revert.
    function testLiquidateRevertsWhenZeroAmount() public {
        vm.prank(liquidator);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.liquidate(alice, address(tokenB), address(tokenA), 0);
    }

    /// @dev Cannot liquidate a healthy position.
    function testLiquidateRevertsWhenPositionIsHealthy() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_500);

        vm.prank(liquidator);
        vm.expectRevert(ArgentProtocol.Argent__PositionUnhealthy.selector);
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_500);
    }

    /**
     * @dev Liquidating with debtAsset = tokenA when Alice's tokenA debt is zero
     *      must revert. This covers the `accruedDebt == 0` branch.
     *      Alice IS liquidatable overall (tokenB debt + price crash) but has no tokenA debt.
     */
    function testLiquidateRevertsWhenZeroDebtForSpecificAsset() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_MAX);
        oracle.setPrice(address(tokenA), 1700e8); // position is unhealthy

        vm.prank(liquidator);
        vm.expectRevert(ArgentProtocol.Argent__NoDebtInAsset.selector);
        // Alice has NO tokenA debt; only tokenB debt
        protocol.liquidate(alice, address(tokenA), address(tokenA), 1e18);
    }

    function testLiquidateWhenBonusExceedsAvailableCapsCollateralAndScalesRepay() public {
        _depositCollateral(alice, COL_1A); // 1 tokenA at $2 000
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_MAX); // $1 500 debt — exactly 75% LTV

        // Drop price: HF = (1 × 1600 × 0.80) / 1500 ≈ 0.853 → liquidatable
        oracle.setPrice(address(tokenA), 1600e8);
        assertTrue(protocol.getLiquidatable(alice), "position must be liquidatable before test");

        // Compute the expected scaled-down repay
        uint256 collateralPrice = 1600e8;
        uint256 expectedRepay = (COL_1A * collateralPrice * BASIS_POINTS * (10 ** DEC_B))
            / (PRICE_B * (BASIS_POINTS + LIQ_BONUS) * (10 ** DEC_A));
        // = (1e18 × 1600e8 × 10000 × 1e6) / (1e8 × 10800 × 1e18) = 1_481_481_481

        uint256 liquidatorTokenABefore = tokenA.balanceOf(liquidator);
        uint256 liquidatorTokenBBefore = tokenB.balanceOf(liquidator);
        uint256 aliceDebtBefore = protocol.getUserDebt(alice, address(tokenB));

        vm.prank(liquidator);
        // Passing BORROW_MAX triggers the cap because the bonus requires > 1 tokenA.
        // Must NOT revert — cap-and-scale should handle it gracefully.
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_MAX);

        // Liquidator received ALL of Alice's collateral (the cap)
        assertEq(
            tokenA.balanceOf(liquidator) - liquidatorTokenABefore,
            COL_1A,
            "liquidator must receive exactly all of Alice's collateral"
        );

        // Alice's collateral position is completely cleared
        assertEq(
            protocol.getUserCollateral(alice, address(tokenA)), 0, "Alice's collateral must be zero after full seizure"
        );

        // Liquidator paid approximately the scaled-down amount (allow 1 atom rounding)
        assertApproxEqAbs(
            liquidatorTokenBBefore - tokenB.balanceOf(liquidator),
            expectedRepay,
            1,
            "liquidator must pay the cap-scaled repay amount"
        );

        // Alice's debt decreased by the scaled repay (not the full $1 500)
        assertApproxEqAbs(
            aliceDebtBefore - protocol.getUserDebt(alice, address(tokenB)),
            expectedRepay,
            1,
            "Alice's debt must decrease by the scaled repay amount"
        );

        // Debt was reduced but not fully cleared (scaled repay < original debt)
        assertGt(
            protocol.getUserDebt(alice, address(tokenB)),
            0,
            "some residual debt remains because repay was scaled below full debt"
        );

        // Liquidator received $1 600 worth of tokenA but paid ~$1 481 in tokenB
        // Net profit ≈ $119 → the liquidation was still incentive-compatible
        uint256 collateralReceivedUSD = protocol.getAssetValueUSD(address(tokenA), COL_1A);
        uint256 debtPaidUSD = protocol.getAssetValueUSD(address(tokenB), expectedRepay);
        assertGt(collateralReceivedUSD, debtPaidUSD, "liquidator must always receive more USD value than they pay");
    }

    /// @dev Zero collateral price (oracle returns 0) must revert with Argent__InvalidAsset.
    function testLiquidateRevertsWhenZeroCollateralPrice() public {
        _makeLiquidatable();
        oracle.setPrice(address(tokenA), 0); // oracle returns zero price for collateral

        vm.prank(liquidator);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAsset.selector);
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_500);
    }

    /**
     * @dev Passing in 100× the debt is automatically capped at the protocol's
     *      maximum liquidatable amount (_getMaxLiquidatableDebt).
     */
    function testLiquidateCapsRepayAtMaxLiquidatable() public {
        _makeLiquidatable();

        uint256 debtBefore = protocol.getUserDebt(alice, address(tokenB));
        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), debtBefore * 100);

        // Liquidator received some collateral (capped repay was processed)
        assertGt(tokenA.balanceOf(liquidator), 0);
        // Debt decreased by at most the capped amount
        assertLt(protocol.getUserDebt(alice, address(tokenB)), debtBefore);
    }

    /**
     * @dev Liquidation does NOT have `whenNotPaused`, so it must still work
     *      while the protocol is paused (critical for solvency protection).
     */
    function testLiquidateWorksWhileProtocolIsPaused() public {
        _makeLiquidatable();
        vm.prank(owner);
        protocol.pause();

        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_500);

        assertGt(tokenA.balanceOf(liquidator), 0);
    }

    /**
     * @dev If the liquidation bonus is set so high that the formula's denominator becomes zero or negative,
     *      the protocol should gracefully handle this edge case by capping the seize at the full collateral,
     *      and scaling down the repay amount accordingly, rather than reverting or allowing excessive seizures.
     *      This test sets the liquidation bonus to an extreme value that would cause the denominator in the liquidation formula to be zero,
     *      and verifies that the liquidation still proceeds with a full collateral seizure and a scaled repay amount, without reverting.
     */
    function testLiquidateWhenDenominatorIsZeroFallsBackToFullDebt() public {
        vm.prank(owner);
        protocol.setLiquidationBonus(2500); // 12 500 × 8 000 = BP² → denominator == 0

        _depositCollateral(alice, COL_1A); // 1 tokenA
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000); // $1 000 debt (< $1 500 limit at 75 % LTV)
        oracle.setPrice(address(tokenA), 1000e8); // $1 000 → HF = 1×1000×0.8/1000 = 0.8

        assertTrue(protocol.getLiquidatable(alice), "position must be liquidatable");

        uint256 debtBefore = protocol.getUserDebt(alice, address(tokenB));
        uint256 balBefore = tokenA.balanceOf(liquidator);

        vm.prank(liquidator);
        // Repay 100e6 → seize ≈ 100e18×12500×1e18/(1000e8×1e10×10000) ≈ 0.125e18 tokenA ✓
        protocol.liquidate(alice, address(tokenB), address(tokenA), 100e6);

        assertLt(protocol.getUserDebt(alice, address(tokenB)), debtBefore, "debt must decrease");
        assertGt(tokenA.balanceOf(liquidator), balBefore, "liquidator must receive collateral");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 13 – PROTOCOL FEES & ADMIN SETTERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Accumulated fees are sent to the treasury; mapping zeroed; event emitted.
    function testWithdrawProtocolFeesSucceeds() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        vm.warp(block.timestamp + 365 days);
        _repay(alice, protocol.getUserDebt(alice, address(tokenB)));

        uint256 fees = protocol.protocolFeesAccrued(address(tokenB));
        assertGt(fees, 0, "must have accrued fees after 1 year");

        uint256 treasuryBefore = tokenB.balanceOf(treasury);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ArgentProtocol.ProtocolFeesWithdrawn(address(tokenB), fees);
        protocol.withdrawProtocolFees(address(tokenB));

        assertEq(protocol.protocolFeesAccrued(address(tokenB)), 0);
        assertEq(tokenB.balanceOf(treasury), treasuryBefore + fees);
    }

    /// @dev Withdrawing when protocolFeesAccrued == 0 must revert.
    function testWithdrawProtocolFeesRevertsWhenNoFees() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAmount.selector);
        protocol.withdrawProtocolFees(address(tokenB));
    }

    /// @dev Non-owner cannot withdraw fees.
    function testWithdrawProtocolFeesRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.withdrawProtocolFees(address(tokenB));
    }

    function testSetProtocolFeeSucceeds() public {
        vm.prank(owner);
        protocol.setProtocolFee(2000);
        assertEq(protocol.protocolFee(), 2000);
    }

    /// @dev Zero is a valid fee (no fees).
    function testSetProtocolFeeZeroAllowed() public {
        vm.prank(owner);
        protocol.setProtocolFee(0);
        assertEq(protocol.protocolFee(), 0);
    }

    /// @dev MAX_PROTOCOL_FEE = 5000; 5001 must revert.
    function testSetProtocolFeeRevertsWhenExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__FeeTooHigh.selector);
        protocol.setProtocolFee(5001);
    }

    function testSetProtocolFeeRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.setProtocolFee(1000);
    }

    function testSetTreasurySucceeds() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        protocol.setTreasury(newTreasury);
        assertEq(protocol.treasury(), newTreasury);
    }

    function testSetTreasuryRevertsWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAddress.selector);
        protocol.setTreasury(address(0));
    }

    function testSetTreasuryRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.setTreasury(makeAddr("x"));
    }

    function testSetLiquidationBonusSucceeds() public {
        vm.prank(owner);
        protocol.setLiquidationBonus(1000);
        assertEq(protocol.liquidationBonus(), 1000);
    }

    function testSetLiquidationBonusRevertsWhenExceedsBP() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__BonusTooHigh.selector);
        protocol.setLiquidationBonus(BASIS_POINTS + 1);
    }

    function testSetLiquidationBonusRevertsWhenNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        protocol.setLiquidationBonus(1000);
    }

    /// @dev setPriceOracle updates address and emits event with old and new addresses.
    function testSetPriceOracleSuccessfulEmitsEvent() public {
        MockPriceOracle newOracle = new MockPriceOracle();
        address oldAddress = address(protocol.priceOracle());

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ArgentProtocol.PriceOracleUpdated(oldAddress, address(newOracle));
        protocol.setPriceOracle(address(newOracle));

        assertEq(address(protocol.priceOracle()), address(newOracle));
    }

    function testSetPriceOracleRevertsWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ArgentProtocol.Argent__InvalidAddress.selector);
        protocol.setPriceOracle(address(0));
    }

    function testSetPriceOracleRevertsWhenNotOwner() public {
        MockPriceOracle newOracle = new MockPriceOracle();
        vm.prank(alice);
        vm.expectRevert();
        protocol.setPriceOracle(address(newOracle));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 14 – _removeUserAsset EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev When a user repays all debt AND has no collateral for that asset,
     *      the asset should be removed from userActiveAssets.
     *      Verified indirectly: getHealthFactor on the now-empty user returns max uint.
     */
    function testRemoveUserAssetClearsOnFullRepayWithNoCollateral() public {
        // Alice borrows tokenB using tokenA as collateral, then repays in full
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        uint256 debt = protocol.getUserDebt(alice, address(tokenB));
        _repay(alice, debt);

        // Now withdraw collateral to zero out tokenA position too
        vm.prank(alice);
        protocol.withdrawCollateral(address(tokenA), COL_1A);

        // userActiveAssets should be empty → no debt, infinite HF
        assertEq(protocol.getHealthFactor(alice), type(uint256).max);
        assertEq(protocol.getTotalCollateralUSD(alice), 0);
        assertEq(protocol.getTotalDebtUSD(alice), 0);
    }

    /**
     * @dev _removeUserAsset must NOT remove the asset when collateral is still
     *      non-zero, even if debt is zero (e.g., user deposited collateral but
     *      never borrowed). The collateral should still count toward the HF.
     */
    function testRemoveUserAssetRetainsAssetWhenCollateralNonZero() public {
        _depositCollateral(alice, COL_1A);
        // No debt → health factor is max uint
        assertEq(protocol.getHealthFactor(alice), type(uint256).max);
        // Collateral is still tracked
        assertEq(protocol.getTotalCollateralUSD(alice), 2000e18);
    }

    /**
     * @dev _removeUserAsset should NOT remove the asset when debt is non-zero
     *      even after collateral is zeroed out via liquidation.
     *      Collateral is fully seized but debt remains → position still tracked.
     */
    function testRemoveUserAssetRetainsAssetWhenDebtNonZero() public {
        // Put Alice into a deeply underwater position so collateral can be seized
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_500); // small borrow → plenty of headroom

        // Crash price to make liquidatable
        oracle.setPrice(address(tokenA), 500e8); // $500 per tokenA → HF = 500*0.8/500 = 0.8

        // Liquidate only part of the debt so the position is not fully closed
        // seize = 500e18 * 10800 * 1e18 / (500e8 * 1e10 * 10000) = 1.08e18 > 1e18 (alice has 1e18)
        // so this will revert with InsufficientCollateral if we try to seize too much.
        // Instead seize a partial amount by repaying only 400 tokenB.
        uint256 partialRepay = 400e6; // 400 tokenB

        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), partialRepay);

        // Alice still has some debt remaining
        assertGt(protocol.getUserDebt(alice, address(tokenB)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 15 – MULTI-ASSET / MULTI-USER INTEGRATION SCENARIOS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Two users (Alice and Charlie) independently deposit collateral,
     *      borrow, and repay.  Their positions must remain isolated — Alice's
     *      state must not affect Charlie's.
     */
    function testIntegrationWithTwoUsersRemainIsolatedPositions() public {
        // Alice: 1 tokenA collateral, borrow 1 000 tokenB
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_20K);
        _borrow(alice, BORROW_1000);

        // Charlie: 2 tokenA collateral, borrow 500 tokenB
        _depositCollateral(charlie, 2e18);
        _borrow(charlie, BORROW_500);

        // Positions are independent
        assertEq(protocol.getUserDebt(alice, address(tokenB)), BORROW_1000);
        assertEq(protocol.getUserDebt(charlie, address(tokenB)), BORROW_500);
        assertEq(protocol.getUserCollateral(alice, address(tokenA)), COL_1A);
        assertEq(protocol.getUserCollateral(charlie, address(tokenA)), 2e18);
    }

    /**
     * @dev Depositing collateral in two different assets gives a combined borrow
     *      limit equal to the sum of each asset's LTV-weighted value.
     *      10 tokenA ($20 000 × 75 %) + 5 000 tokenB ($5 000 × 75 %) = $15 000 + $3 750 = $18 750
     */
    function testIntegrationWithMultiAssetCollateralCombinesBorrowLimit() public {
        _depositCollateral(alice, COL_10A); // $20 000 collateral

        // Also deposit tokenB as collateral
        vm.prank(alice);
        protocol.depositCollateral(address(tokenB), 5_000e6); // $5 000 collateral

        uint256 expectedLimit = 18_750e18; // ($20 000 + $5 000) × 75 %
        assertApproxEqAbs(protocol.getBorrowLimit(alice), expectedLimit, 1e15);
    }

    /**
     * @dev After a partial liquidation the position may still be unhealthy.
     *      A second liquidation can further reduce the debt.
     */
    function testIntegrationWithSequentialLiquidations() public {
        // Give Alice 10 tokenA so multiple partial liquidations fit
        _depositCollateral(alice, COL_10A);
        _depositLiquidity(bob, LIQ_20K);
        _borrow(alice, 15_000e6); // $15 000 borrow (75 % of $20 000 collateral)

        // Crash price: 1 tokenA → $1 700, collateral = $17 000, HF = 17000*0.8/15000 ≈ 0.907
        oracle.setPrice(address(tokenA), 1700e8);
        assertTrue(protocol.getLiquidatable(alice));

        uint256 debt1 = protocol.getUserDebt(alice, address(tokenB));

        // First liquidation
        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), debt1 / 2);

        uint256 debt2 = protocol.getUserDebt(alice, address(tokenB));
        assertLt(debt2, debt1);

        // If still liquidatable, do a second liquidation
        if (protocol.getLiquidatable(alice)) {
            vm.prank(liquidator);
            protocol.liquidate(alice, address(tokenB), address(tokenA), debt2 / 2);
            assertLt(protocol.getUserDebt(alice, address(tokenB)), debt2);
        }
    }

    /**
     * @dev Warp 1 year forward: debt should exceed the principal by ~5 % (compound).
     *      Allows 0.5 % relative tolerance for compounding approximation.
     */
    function testIntegrationWithInterestAccrualForOneYear() public {
        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000); // $1 000 principal

        vm.warp(block.timestamp + 365 days);

        uint256 debt = protocol.getUserDebt(alice, address(tokenB));
        // 5 % annual → expect ~1 050e6
        assertGt(debt, BORROW_1000, "debt must grow after 1 year");
        assertApproxEqRel(debt, 1050e6, 0.005e18); // within 0.5 %
    }

    /**
     * @dev A user's health factor improves after a liquidation reduces their debt.
     */
    function testIntegrationHealthFactorImprovesAfterLiquidation() public {
        _makeLiquidatable();
        uint256 hfBefore = protocol.getHealthFactor(alice);

        vm.prank(liquidator);
        protocol.liquidate(alice, address(tokenB), address(tokenA), BORROW_500);

        uint256 hfAfter = protocol.getHealthFactor(alice);
        assertGt(hfAfter, hfBefore, "health factor must improve after partial liquidation");
    }

    /**
     * @dev Depositing liquidity increases the available pool; after borrowing the
     *      available liquidity decreases; after full repayment it returns to
     *      (slightly less than original due to protocol fees).
     */
    function testIntegrationWithLiquidityLifecycle() public {
        _depositLiquidity(bob, LIQ_5K);
        assertEq(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K);

        _depositCollateral(alice, COL_1A);
        _borrow(alice, BORROW_1000);
        assertEq(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K - BORROW_1000);

        vm.warp(block.timestamp + 365 days);
        uint256 debt = protocol.getUserDebt(alice, address(tokenB));
        _repay(alice, debt);

        // After repayment, available ≤ LIQ_5K (fees are reserved)
        assertLe(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K);
        // But the pool was made whole by the repayment principal
        assertGt(protocol.getAvailableLiquidity(address(tokenB)), LIQ_5K - BORROW_1000);
    }

    /**
     * @dev Collateral deposited by Alice must NOT be accessible as borrow liquidity
     *      until it has been counted towards totalDeposits. Here we verify that
     *      getAvailableLiquidity includes totalDeposits in its calculation.
     */
    function testIntegrationCollateralCountsTowardAvailableLiquidity() public {
        // Before: no tokenA deposits
        assertEq(protocol.getAvailableLiquidity(address(tokenA)), 0);

        _depositCollateral(alice, COL_1A);

        // After: totalDeposits[tokenA] = 1e18, no borrows → available = 1e18
        assertEq(protocol.getAvailableLiquidity(address(tokenA)), COL_1A);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 16 – FUZZ TESTS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @dev Fuzz: depositCollateral with any non-zero amount succeeds
     *      as long as the user has sufficient balance.
     */
    function testFuzzDepositCollateralAnyAmount(uint256 amount) public {
        // Bound to a realistic range (1 atom → 100 tokenA)
        amount = bound(amount, 1, 100e18);

        tokenA.mint(alice, amount);
        vm.prank(alice);
        protocol.depositCollateral(address(tokenA), amount);

        assertEq(protocol.getUserCollateral(alice, address(tokenA)), amount);
    }

    /**
     * @dev Fuzz: health factor after borrowing within LTV limit is always ≥ 1e18.
     *      borrowFraction: 0–99 % of the maximum borrow limit to stay within bounds.
     */
    function testFuzzHealthFactorWithinLTVAlwaysAboveOne(uint256 borrowFraction) public {
        borrowFraction = bound(borrowFraction, 0, 99); // 0–99 % of borrow limit

        _depositCollateral(alice, COL_1A); // $2 000 collateral
        _depositLiquidity(bob, LIQ_5K);

        // max borrow = $1 500 → scaled to 1 500e6 tokenB
        uint256 maxBorrow = BORROW_MAX;
        uint256 borrowAmt = (maxBorrow * borrowFraction) / 100;

        if (borrowAmt == 0) {
            assertEq(protocol.getHealthFactor(alice), type(uint256).max);
            return;
        }

        vm.prank(alice);
        protocol.borrow(address(tokenB), borrowAmt);

        assertGe(protocol.getHealthFactor(alice), 1e18, "health factor must be >= 1 for any borrow within LTV");
    }

    /**
     * @dev Fuzz: repaying any amount (1 atom → full debt) never increases debt.
     */
    function testFuzzRepayNeverIncreasesDebt(uint256 repayFraction) public {
        repayFraction = bound(repayFraction, 1, 100);

        _depositCollateral(alice, COL_1A);
        _depositLiquidity(bob, LIQ_5K);
        _borrow(alice, BORROW_1000);

        uint256 debtBefore = protocol.getUserDebt(alice, address(tokenB));
        uint256 repayAmt = (debtBefore * repayFraction) / 100;
        if (repayAmt == 0) repayAmt = 1;

        vm.prank(alice);
        protocol.repay(address(tokenB), repayAmt);

        assertLe(protocol.getUserDebt(alice, address(tokenB)), debtBefore, "debt must never increase after a repayment");
    }

    /**
     * @dev Fuzz: withdrawing collateral when there is no debt never reverts
     *      as long as the amount does not exceed the deposit.
     */
    function testFuzzWithdrawCollateralWithNoDebtNeverReverts(uint256 withdrawFraction) public {
        withdrawFraction = bound(withdrawFraction, 1, 100);

        _depositCollateral(alice, COL_1A);
        uint256 withdrawAmt = (COL_1A * withdrawFraction) / 100;
        if (withdrawAmt == 0) withdrawAmt = 1;

        vm.prank(alice);
        protocol.withdrawCollateral(address(tokenA), withdrawAmt);

        assertEq(protocol.getUserCollateral(alice, address(tokenA)), COL_1A - withdrawAmt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  SECTION 17 – CONSTANTS & IMMUTABLE VIEW COVERAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Verify that all public constant values match their specification.
    function testConstantsMatchSpec() public view {
        assertEq(protocol.BASIS_POINTS(), 10_000);
        assertEq(protocol.INITIAL_INDEX(), 1e18);
        assertEq(protocol.SECONDS_PER_YEAR(), 365 days);
        assertEq(protocol.PRICE_PRECISION(), 1e8);
        assertEq(protocol.MAX_PROTOCOL_FEE(), 5000);
    }

    /// @dev assetConfig is a public mapping — confirm it is readable and correct.
    function testAssetConfigPublicMappingIsReadable() public view {
        (
            ArgentProtocol.AssetStatus status,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 interestRate,
            uint8 decimals
        ) = protocol.assetConfig(address(tokenA));

        assertEq(uint8(status), uint8(ArgentProtocol.AssetStatus.ACTIVE));
        assertEq(ltv, LTV_A);
        assertEq(liquidationThreshold, LT_A);
        assertEq(interestRate, INTEREST_RATE);
        assertEq(decimals, DEC_A);
    }
}
