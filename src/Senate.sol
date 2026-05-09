// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorStorage} from "@openzeppelin/contracts/governance/extensions/GovernorStorage.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Senate
 * @author Ogolo Boma
 * @notice The on-chain governance contract for the Argent Protocol.
 * @dev Inherits from OpenZeppelin's Governor and related extensions to implement a robust governance system.
 */
contract Senate is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorStorage,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // ========================================
    // CONSTRUCTOR
    // ========================================

    /**
     * @notice Initializes the Senate governance contract with the specified token and timelock.
     * @param _token The address of the ERC20 token used for voting (e.g., Argentum).
     * @param _timelock The address of the TimelockController that will manage the execution of successful proposals.
     * @dev The constructor sets up the governance parameters, including the voting delay, voting period, and proposal threshold. It also initializes the GovernorVotes extension with the specified token and the GovernorTimelockControl extension with the specified timelock. This setup ensures that the governance process is secure and that proposals are executed in a timely manner after passing the voting process.
     */
    constructor(IVotes _token, TimelockController _timelock)
        Governor("Senate")
        GovernorSettings(7200, 50400, 500e18) // 1 day voting delay, 7 days voting period, 500 ARG proposal threshold
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4)
        GovernorTimelockControl(_timelock)
    {}

    // ========================================
    // PUBLIC OVERRIDE FUNCTIONS
    // ========================================

    /**
     * @notice Returns the state of a proposal, including whether it is active, succeeded, queued, executed, or canceled.
     * @dev Overrides the state function to incorporate the logic from both Governor and GovernorTimelockControl, ensuring that the proposal's state reflects its status in relation to the timelock.
     * @param proposalId The ID of the proposal to check.
     * @return ProposalState
     */
    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    /**
     * @notice Determines if a proposal needs to be queued in the timelock after it has succeeded.
     * @dev Overrides the proposalNeedsQueuing function to ensure that it correctly identifies when a proposal has succeeded and requires queuing in the timelock before execution. This is crucial for maintaining the integrity of the governance process and ensuring that proposals are executed in a timely manner after passing.
     * @param proposalId The ID of the proposal to check.
     * @return bool indicating whether the proposal needs queuing.
     */
    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    /**
     * @notice Returns the proposal threshold, which is the minimum number of votes required for a proposal to be considered valid and move forward in the governance process.
     * @dev Overrides the proposalThreshold function to ensure that it correctly reflects the threshold set in the GovernorSettings extension. This threshold is crucial for preventing spam proposals and ensuring that only proposals with sufficient support are considered for voting.
     * @return uint256 The proposal threshold in terms of voting power (e.g., 500 ARG).
     */
    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    // ========================================
    // INTERNAL OVERRIDE FUNCTIONS
    // ========================================

    /**
     * @notice Internal function to handle the proposal creation logic, including validation and storage of proposal details.
     * @dev Overrides the _propose function to ensure that it correctly integrates the logic from both Governor and GovernorStorage, allowing for proper handling of proposal creation while maintaining the necessary storage structure for proposals. This function is responsible for validating the proposal parameters and storing the proposal details in the contract's state.
     * @param targets The list of target addresses for the proposed actions.
     * @param values The list of ETH values to be sent with each action.
     * @param calldatas The list of calldata for each action.
     * @param description A string description of the proposal.
     * @param proposer The address of the proposer creating the proposal.
     * @return uint256 The ID of the newly created proposal.
     */
    function _propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        address proposer
    ) internal override(Governor, GovernorStorage) returns (uint256) {
        return super._propose(targets, values, calldatas, description, proposer);
    }

    /**
     * @notice Internal function to handle the queuing of successful proposals in the timelock, ensuring that they are scheduled for execution after the appropriate delay.
     * @dev Overrides the _queueOperations function to ensure that it correctly integrates the logic from both Governor and GovernorTimelockControl, allowing for proper handling of proposal queuing while maintaining the necessary interactions with the timelock. This function is responsible for scheduling the execution of successful proposals in the timelock after they have passed the voting process, ensuring that there is a delay before execution to allow for any necessary preparations or objections.
     * @param proposalId The ID of the proposal being queued.
     * @param targets The list of target addresses for the proposed actions.
     * @param values The list of ETH values to be sent with each action.
     * @param calldatas The list of calldata for each action.
     * @param descriptionHash The hash of the proposal description.
     * @return uint48 The timestamp at which the proposal is scheduled for execution in the timelock.
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Internal function to handle the execution of queued proposals, ensuring that they are executed in accordance with the timelock's scheduling and requirements.
     * @dev Overrides the _executeOperations function to ensure that it correctly integrates the logic from both Governor and GovernorTimelockControl, allowing for proper handling of proposal execution while maintaining the necessary interactions with the timelock. This function is responsible for executing the actions specified in a proposal after it has been queued and the timelock delay has passed, ensuring that the execution is carried out in a secure and orderly manner.
     * @param proposalId The ID of the proposal being executed.
     * @param targets The list of target addresses for the proposed actions.
     * @param values The list of ETH values to be sent with each action.
     * @param calldatas The list of calldata for each action.
     * @param descriptionHash The hash of the proposal description.
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Internal function to handle the cancellation of proposals, ensuring that they are properly marked as canceled and cannot be executed.
     * @dev Overrides the _cancel function to ensure that it correctly integrates the logic from both Governor and GovernorTimelockControl, allowing for proper handling of proposal cancellation while maintaining the necessary interactions with the timelock. This function is responsible for marking a proposal as canceled, preventing it from being executed if it has not already been executed or if it is still in the voting process.
     * @param targets The list of target addresses for the proposed actions.
     * @param values The list of ETH values to be sent with each action.
     * @param calldatas The list of calldata for each action.
     * @param descriptionHash The hash of the proposal description.
     * @return uint256 The ID of the canceled proposal.
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    /**
     * @notice Internal function to return the address of the executor, which is the timelock contract responsible for executing successful proposals.
     * @dev Overrides the _executor function to ensure that it correctly returns the address of the timelock contract, which is essential for the proper functioning of the governance system. This function is used by the GovernorTimelockControl extension to determine where to send the execution calls for successful proposals, ensuring that they are executed in accordance with the timelock's scheduling and requirements.
     * @return address The address of the timelock contract acting as the executor.
     */
    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
