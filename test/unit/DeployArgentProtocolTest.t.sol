// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {DeployArgentProtocol} from "../../script/DeployArgentProtocol.s.sol";

import {Treasury} from "../../src/Treasury.sol";
import {Argentum} from "../../src/Argentum.sol";
import {ArgentTimelock} from "../../src/ArgentTimelock.sol";
import {Senate} from "../../src/Senate.sol";
import {PriceOracle} from "../../src/PriceOracle.sol";
import {ArgentProtocol} from "../../src/ArgentProtocol.sol";

contract DeployArgentProtocolTest is Test {
    // =============================================================
    // SCRIPT
    // =============================================================

    DeployArgentProtocol internal deployerScript;

    // =============================================================
    // DEPLOYED CONTRACTS
    // =============================================================

    Treasury internal treasury;
    Argentum internal argentum;
    ArgentTimelock internal timelock;
    Senate internal senate;
    PriceOracle internal oracle;
    ArgentProtocol internal protocol;

    // =============================================================
    // TEST CONFIG
    // =============================================================

    address internal deployer = makeAddr("deployer");

    // Mock asset addresses
    address internal WBTC = makeAddr("WBTC");
    address internal DAI = makeAddr("DAI");
    address internal LINK = makeAddr("LINK");
    address internal USDC = makeAddr("USDC");
    address internal WETH = makeAddr("WETH");
    address internal USDT = makeAddr("USDT");

    // Mock feed addresses
    address internal WBTC_FEED = makeAddr("WBTC_FEED");
    address internal DAI_FEED = makeAddr("DAI_FEED");
    address internal LINK_FEED = makeAddr("LINK_FEED");
    address internal USDC_FEED = makeAddr("USDC_FEED");
    address internal WETH_FEED = makeAddr("WETH_FEED");
    address internal USDT_FEED = makeAddr("USDT_FEED");

    // =============================================================
    // SETUP
    // =============================================================

    function setUp() public {
        // ---------------------------------------------------------
        // ENV
        // ---------------------------------------------------------

        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        vm.setEnv("MIN_DELAY", "60");

        vm.setEnv("PROTOCOL_FEE", "1500");
        vm.setEnv("LIQUIDATION_BONUS", "800");

        // ---------------------------------------------------------
        // WBTC
        // ---------------------------------------------------------

        vm.setEnv("mWBTC_ADDRESS", vm.toString(WBTC));
        vm.setEnv("mWBTC_CHAINLINK_FEED", vm.toString(WBTC_FEED));
        vm.setEnv("mWBTC_HEARTBEAT", "86400");
        vm.setEnv("mWBTC_LTV", "7000");
        vm.setEnv("mWBTC_LT", "7500");
        vm.setEnv("mWBTC_INTEREST_RATE", "500");
        vm.setEnv("mWBTC_DECIMALS", "8");

        // ---------------------------------------------------------
        // DAI
        // ---------------------------------------------------------

        vm.setEnv("mDAI_ADDRESS", vm.toString(DAI));
        vm.setEnv("mDAI_CHAINLINK_FEED", vm.toString(DAI_FEED));
        vm.setEnv("mDAI_HEARTBEAT", "86400");
        vm.setEnv("mDAI_LTV", "7500");
        vm.setEnv("mDAI_LT", "8000");
        vm.setEnv("mDAI_INTEREST_RATE", "600");
        vm.setEnv("mDAI_DECIMALS", "18");

        // ---------------------------------------------------------
        // LINK
        // ---------------------------------------------------------

        vm.setEnv("mLINK_ADDRESS", vm.toString(LINK));
        vm.setEnv("mLINK_CHAINLINK_FEED", vm.toString(LINK_FEED));
        vm.setEnv("mLINK_HEARTBEAT", "86400");
        vm.setEnv("mLINK_LTV", "5000");
        vm.setEnv("mLINK_LT", "6500");
        vm.setEnv("mLINK_INTEREST_RATE", "400");
        vm.setEnv("mLINK_DECIMALS", "18");

        // ---------------------------------------------------------
        // USDC
        // ---------------------------------------------------------

        vm.setEnv("mUSDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("mUSDC_CHAINLINK_FEED", vm.toString(USDC_FEED));
        vm.setEnv("mUSDC_HEARTBEAT", "86400");
        vm.setEnv("mUSDC_LTV", "7500");
        vm.setEnv("mUSDC_LT", "8000");
        vm.setEnv("mUSDC_INTEREST_RATE", "600");
        vm.setEnv("mUSDC_DECIMALS", "6");

        // ---------------------------------------------------------
        // WETH
        // ---------------------------------------------------------

        vm.setEnv("mWETH_ADDRESS", vm.toString(WETH));
        vm.setEnv("mWETH_CHAINLINK_FEED", vm.toString(WETH_FEED));
        vm.setEnv("mWETH_HEARTBEAT", "86400");
        vm.setEnv("mWETH_LTV", "8000");
        vm.setEnv("mWETH_LT", "8500");
        vm.setEnv("mWETH_INTEREST_RATE", "500");
        vm.setEnv("mWETH_DECIMALS", "18");

        // ---------------------------------------------------------
        // USDT
        // ---------------------------------------------------------

        vm.setEnv("mUSDT_ADDRESS", vm.toString(USDT));
        vm.setEnv("mUSDT_CHAINLINK_FEED", vm.toString(USDT_FEED));
        vm.setEnv("mUSDT_HEARTBEAT", "86400");
        vm.setEnv("mUSDT_LTV", "7500");
        vm.setEnv("mUSDT_LT", "8000");
        vm.setEnv("mUSDT_INTEREST_RATE", "600");
        vm.setEnv("mUSDT_DECIMALS", "6");

        // ---------------------------------------------------------
        // DEPLOY SCRIPT
        // ---------------------------------------------------------

        deployerScript = new DeployArgentProtocol();

        deployerScript.run();

        // ---------------------------------------------------------
        // FETCH DEPLOYED CONTRACTS
        // ---------------------------------------------------------

        treasury = deployerScript.treasury();
        argentum = deployerScript.argentum();
        timelock = deployerScript.timelock();
        senate = deployerScript.senate();
        oracle = deployerScript.oracle();
        protocol = deployerScript.protocol();
    }

    // =============================================================
    // DEPLOYMENT TESTS
    // =============================================================

    function testContractsDeploySuccessfully() public view {
        assertTrue(address(treasury) != address(0));
        assertTrue(address(argentum) != address(0));
        assertTrue(address(timelock) != address(0));
        assertTrue(address(senate) != address(0));
        assertTrue(address(oracle) != address(0));
        assertTrue(address(protocol) != address(0));
    }

    // =============================================================
    // OWNERSHIP TESTS
    // =============================================================

    function testOwnershipTransferredToTimelock() public view {
        assertEq(protocol.owner(), address(timelock));
        assertEq(oracle.owner(), address(timelock));
        assertEq(argentum.owner(), address(timelock));
        assertEq(treasury.owner(), address(timelock));
    }

    // =============================================================
    // GOVERNANCE ROLE TESTS
    // =============================================================

    function testSenateHasProposerRole() public view {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();

        assertTrue(timelock.hasRole(proposerRole, address(senate)));
    }

    function testExecutorRoleIsOpen() public view {
        bytes32 executorRole = timelock.EXECUTOR_ROLE();

        assertTrue(timelock.hasRole(executorRole, address(0)));
    }

    function testDeployerNoLongerAdmin() public view {
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        assertFalse(timelock.hasRole(adminRole, deployer));
    }

    // =============================================================
    // ORACLE TESTS
    // =============================================================

    function testOracleFeedsRegistered() public view {
        assertEq(oracle.priceFeeds(WBTC), WBTC_FEED);
        assertEq(oracle.priceFeeds(DAI), DAI_FEED);
        assertEq(oracle.priceFeeds(LINK), LINK_FEED);
        assertEq(oracle.priceFeeds(USDC), USDC_FEED);
        assertEq(oracle.priceFeeds(WETH), WETH_FEED);
        assertEq(oracle.priceFeeds(USDT), USDT_FEED);
    }

    function testOracleHeartbeatsRegistered() public view {
        assertEq(oracle.heartbeats(WBTC), 86400);
        assertEq(oracle.heartbeats(DAI), 86400);
        assertEq(oracle.heartbeats(LINK), 86400);
        assertEq(oracle.heartbeats(USDC), 86400);
        assertEq(oracle.heartbeats(WETH), 86400);
        assertEq(oracle.heartbeats(USDT), 86400);
    }

    // =============================================================
    // ASSET REGISTRATION TESTS
    // =============================================================

    function testAssetsRegistered() public view {
        address[] memory supported = protocol.getSupportedAssets();

        assertEq(supported.length, 6);

        assertEq(supported[0], WBTC);
        assertEq(supported[1], DAI);
        assertEq(supported[2], LINK);
        assertEq(supported[3], USDC);
        assertEq(supported[4], WETH);
        assertEq(supported[5], USDT);
    }

    function testWBTCAssetConfig() public view {
        (
            ArgentProtocol.AssetStatus status,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 interestRate,
            uint256 decimals
        ) = protocol.assetConfig(WBTC);

        assertEq(uint256(status), uint256(ArgentProtocol.AssetStatus.ACTIVE));

        assertEq(ltv, 7000);
        assertEq(liquidationThreshold, 7500);
        assertEq(interestRate, 500);
        assertEq(decimals, 8);
    }

    function testUSDCAssetConfig() public view {
        (
            ArgentProtocol.AssetStatus status,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 interestRate,
            uint256 decimals
        ) = protocol.assetConfig(USDC);

        assertEq(uint256(status), uint256(ArgentProtocol.AssetStatus.ACTIVE));
        assertEq(ltv, 7500);
        assertEq(liquidationThreshold, 8000);
        assertEq(interestRate, 600);
        assertEq(decimals, 6);
    }

    // =============================================================
    // GOVERNANCE TOKEN TESTS
    // =============================================================

    function testTreasuryReceivedAllARG() public view {
        uint256 treasuryBalance = argentum.balanceOf(address(treasury));

        uint256 totalSupply = argentum.totalSupply();

        assertEq(treasuryBalance, totalSupply);
    }

    function testTreasuryVotingPowerActivated() public view {
        uint256 votes = argentum.getVotes(address(treasury));

        assertGt(votes, 0);
    }

    // =============================================================
    // INTEGRATION TESTS
    // =============================================================

    function testCannotCallOnlyOwnerFunctionsAfterTransfer() public {
        vm.expectRevert();

        protocol.addAsset(makeAddr("FAKE"), 7000, 8000, 500, 18);
    }

    function testOracleOwnershipLockedToDAO() public {
        vm.expectRevert();

        oracle.setPriceFeed(makeAddr("TOKEN"), makeAddr("FEED"), 1 days);
    }

    // =============================================================
    // FULL SYSTEM SANITY
    // =============================================================

    function testSystemFullyBootstrapped() public view {
        // Assets registered
        assertEq(protocol.getSupportedAssets().length, 6);

        // Oracle configured
        assertEq(oracle.priceFeeds(WETH), WETH_FEED);

        // Governance active
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(senate)));

        // DAO owns protocol
        assertEq(protocol.owner(), address(timelock));
    }
}
