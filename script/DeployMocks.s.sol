// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployMocks is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 mWETH = new MockERC20("Mock WETH", "mWETH", 18);
        MockERC20 mWBTC = new MockERC20("Mock BTC", "mWBTC", 8);
        MockERC20 mUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
        MockERC20 mUSDT = new MockERC20("Mock USDT", "mUSDT", 6);
        MockERC20 mDAI = new MockERC20("Mock DAI", "mDAI", 18);
        MockERC20 mLINK = new MockERC20("Mock LINK", "mLINK", 18);

        address deployer = msg.sender;

        uint256 ONE_MILLION_18 = 1_000_000e18;
        uint256 ONE_MILLION_6 = 1_000_000e6;
        uint256 ONE_MILLION_8 = 1_000_000e8;

        mWETH.mint(deployer, ONE_MILLION_18);
        mWBTC.mint(deployer, ONE_MILLION_8);
        mUSDC.mint(deployer, ONE_MILLION_6);
        mUSDT.mint(deployer, ONE_MILLION_6);
        mDAI.mint(deployer, ONE_MILLION_18);
        mLINK.mint(deployer, ONE_MILLION_18);

        vm.stopBroadcast();

        console.log("=== MOCK TOKEN ADDRESSES ===");
        console.log("mWETH:", address(mWETH));
        console.log("mWBTC:", address(mWBTC));
        console.log("mUSDC:", address(mUSDC));
        console.log("mUSDT:", address(mUSDT));
        console.log("mDAI :", address(mDAI));
        console.log("mLINK:", address(mLINK));
    }
}
