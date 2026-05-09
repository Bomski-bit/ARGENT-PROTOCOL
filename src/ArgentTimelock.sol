// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title ArgentTimelock
 * @author Ogolo Boma
 * @notice The TimelockController for the SENATE.
 * It is the owner of the Treasury and the only proposer and executor.
 */
contract ArgentTimelock is TimelockController {
    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the ArgentTimelock contract.
     * @param minDelay The minimum delay for executing a proposal after it has been queued.
     * @param proposers The list of addresses that can propose actions (should be the timelock itself).
     * @param executors The list of addresses that can execute actions (should be the timelock itself).
     * @param admin The address that will have admin rights over the timelock (initially the deployer or a multisig).
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
