// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Argent Protocol Deployment Script
 * @notice Deploys and bootstraps the full Argent Protocol stack.
 *
 * DEPLOYMENT FLOW:
 * 1. Deploy Treasury
 * 2. Deploy Argentum governance token
 * 3. Deploy Timelock
 * 4. Deploy Senate Governor
 * 5. Deploy PriceOracle
 * 6. Deploy ArgentProtocol
 * 7. Configure oracle feeds
 * 8. Register supported assets
 * 9. Activate governance voting power
 * 10. Wire governance roles
 * 11. Transfer ownerships to Timelock
 */

import {Script, console} from "forge-std/Script.sol";
import {Treasury} from "../src/Treasury.sol";
import {Argentum} from "../src/Argentum.sol";
import {ArgentTimelock} from "../src/ArgentTimelock.sol";
import {Senate} from "../src/Senate.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {ArgentProtocol} from "../src/ArgentProtocol.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployArgentProtocol is Script {
    // =============================================================
    // CONTRACTS
    // =============================================================

    Treasury public treasury;
    Argentum public argentum;
    ArgentTimelock public timelock;
    Senate public senate;
    PriceOracle public oracle;
    ArgentProtocol public protocol;

    // =============================================================
    // CONFIG
    // =============================================================

    address public deployer;

    uint256 public minDelay;
    uint256 public protocolFee;
    uint256 public liquidationBonus;

    // =============================================================
    // ASSET CONFIG
    // =============================================================

    struct AssetConfig {
        string name;
        address token;
        address feed;
        uint256 heartbeat;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 interestRate;
        uint8 decimals;
    }

    AssetConfig[] public assets;

    // =============================================================
    // RUN
    // =============================================================

    function run() external {

        deploy();

        _logDeployment();
    }

    function deploy() public {
        _loadEnvironment();

        vm.startBroadcast(deployer);

        _deployTreasury();
        _deployArgentum();
        _deployTimelock();
        _deploySenate();
        _deployOracle();
        _deployProtocol();

        _configureOracleFeeds();
        _registerAssets();

        _activateVotingPower();

        _wireGovernanceRoles();
        _transferOwnerships();

        vm.stopBroadcast();
    }

    // =============================================================
    // ENVIRONMENT
    // =============================================================

    function _loadEnvironment() internal {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");

        minDelay = vm.envUint("MIN_DELAY");

        protocolFee = vm.envUint("PROTOCOL_FEE");
        liquidationBonus = vm.envUint("LIQUIDATION_BONUS");

        _buildAssetList();

        console.log("==================================");
        console.log("ARGENT PROTOCOL DEPLOYMENT");
        console.log("==================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("");
    }

    function _buildAssetList() internal {
        assets.push(
            AssetConfig({
                name: "mWBTC",
                token: vm.envAddress("mWBTC_ADDRESS"),
                feed: vm.envAddress("mWBTC_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mWBTC_HEARTBEAT"),
                ltv: vm.envUint("mWBTC_LTV"),
                liquidationThreshold: vm.envUint("mWBTC_LT"),
                interestRate: vm.envUint("mWBTC_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mWBTC_DECIMALS"))
            })
        );

        assets.push(
            AssetConfig({
                name: "mDAI",
                token: vm.envAddress("mDAI_ADDRESS"),
                feed: vm.envAddress("mDAI_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mDAI_HEARTBEAT"),
                ltv: vm.envUint("mDAI_LTV"),
                liquidationThreshold: vm.envUint("mDAI_LT"),
                interestRate: vm.envUint("mDAI_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mDAI_DECIMALS"))
            })
        );

        assets.push(
            AssetConfig({
                name: "mLINK",
                token: vm.envAddress("mLINK_ADDRESS"),
                feed: vm.envAddress("mLINK_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mLINK_HEARTBEAT"),
                ltv: vm.envUint("mLINK_LTV"),
                liquidationThreshold: vm.envUint("mLINK_LT"),
                interestRate: vm.envUint("mLINK_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mLINK_DECIMALS"))
            })
        );

        assets.push(
            AssetConfig({
                name: "mUSDC",
                token: vm.envAddress("mUSDC_ADDRESS"),
                feed: vm.envAddress("mUSDC_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mUSDC_HEARTBEAT"),
                ltv: vm.envUint("mUSDC_LTV"),
                liquidationThreshold: vm.envUint("mUSDC_LT"),
                interestRate: vm.envUint("mUSDC_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mUSDC_DECIMALS"))
            })
        );

        assets.push(
            AssetConfig({
                name: "mWETH",
                token: vm.envAddress("mWETH_ADDRESS"),
                feed: vm.envAddress("mWETH_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mWETH_HEARTBEAT"),
                ltv: vm.envUint("mWETH_LTV"),
                liquidationThreshold: vm.envUint("mWETH_LT"),
                interestRate: vm.envUint("mWETH_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mWETH_DECIMALS"))
            })
        );

        assets.push(
            AssetConfig({
                name: "mUSDT",
                token: vm.envAddress("mUSDT_ADDRESS"),
                feed: vm.envAddress("mUSDT_CHAINLINK_FEED"),
                heartbeat: vm.envUint("mUSDT_HEARTBEAT"),
                ltv: vm.envUint("mUSDT_LTV"),
                liquidationThreshold: vm.envUint("mUSDT_LT"),
                interestRate: vm.envUint("mUSDT_INTEREST_RATE"),
                decimals: uint8(vm.envUint("mUSDT_DECIMALS"))
            })
        );
    }

    // =============================================================
    // DEPLOYMENTS
    // =============================================================

    function _deployTreasury() internal {
        treasury = new Treasury(deployer);

        console.log("Treasury:", address(treasury));
    }

    function _deployArgentum() internal {
        argentum = new Argentum(address(treasury), deployer);

        console.log("Argentum:", address(argentum));
    }

    function _deployTimelock() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;

        address[] memory executors = new address[](1);
        executors[0] = address(0);

        timelock = new ArgentTimelock(minDelay, proposers, executors, deployer);

        console.log("Timelock:", address(timelock));
    }

    function _deploySenate() internal {
        senate = new Senate(IVotes(address(argentum)), TimelockController(payable(address(timelock))));

        console.log("Senate:", address(senate));
    }

    function _deployOracle() internal {
        oracle = new PriceOracle(deployer);

        console.log("PriceOracle:", address(oracle));
    }

    function _deployProtocol() internal {
        protocol = new ArgentProtocol(address(oracle), address(treasury), protocolFee, liquidationBonus, deployer);

        console.log("ArgentProtocol:", address(protocol));
    }

    // =============================================================
    // ORACLE CONFIGURATION
    // =============================================================

    function _configureOracleFeeds() internal {
        console.log("");
        console.log("Setting Oracle Feeds...");

        for (uint256 i = 0; i < assets.length; i++) {
            AssetConfig memory asset = assets[i];

            oracle.setPriceFeed(asset.token, asset.feed, asset.heartbeat);

            console.log("Feed set:", asset.name);
        }
    }

    // =============================================================
    // ASSET REGISTRATION
    // =============================================================

    function _registerAssets() internal {
        console.log("");
        console.log("Registering Assets...");

        for (uint256 i = 0; i < assets.length; i++) {
            AssetConfig memory asset = assets[i];

            protocol.addAsset(asset.token, asset.ltv, asset.liquidationThreshold, asset.interestRate, asset.decimals);

            console.log("Registered:", asset.name);
        }
    }

    // =============================================================
    // GOVERNANCE ACTIVATION
    // =============================================================

    function _activateVotingPower() internal {
        console.log("");
        console.log("Activating Voting Power...");

        treasury.delegateToken(address(argentum), address(treasury));

        console.log("Treasury self-delegated ARG voting power");
    }

    // =============================================================
    // GOVERNANCE ROLES
    // =============================================================

    function _wireGovernanceRoles() internal {
        console.log("");
        console.log("Wiring Governance Roles...");

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(senate));

        timelock.grantRole(timelock.CANCELLER_ROLE(), address(senate));

        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(0));

        timelock.revokeRole(timelock.PROPOSER_ROLE(), deployer);

        timelock.revokeRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);

        console.log("Governance wired successfully");
    }

    // =============================================================
    // OWNERSHIP TRANSFERS
    // =============================================================

    function _transferOwnerships() internal {
        console.log("");
        console.log("Transferring Ownerships...");

        protocol.transferOwnership(address(timelock));
        oracle.transferOwnership(address(timelock));
        argentum.transferOwnership(address(timelock));
        treasury.transferOwnership(address(timelock));

        console.log("All ownership transferred to Timelock");
    }

    // =============================================================
    // LOGGING
    // =============================================================

    function _logDeployment() internal view {
        console.log("");
        console.log("==================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("==================================");

        console.log("Treasury       :", address(treasury));
        console.log("Argentum       :", address(argentum));
        console.log("Timelock       :", address(timelock));
        console.log("Senate         :", address(senate));
        console.log("PriceOracle    :", address(oracle));
        console.log("ArgentProtocol :", address(protocol));

        console.log("");
        console.log("Supported Assets:");

        address[] memory supported = protocol.getSupportedAssets();

        for (uint256 i = 0; i < supported.length; i++) {
            console.log(supported[i]);
        }

        console.log("");
        console.log("Protocol fully governed by DAO");
    }
}
