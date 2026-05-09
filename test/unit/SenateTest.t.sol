// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Senate} from "../../src/Senate.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {ERC20Votes, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Permit, Nonces} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

// Mock Vote Token
contract GovernanceToken is ERC20, ERC20Votes, ERC20Permit {
    constructor() ERC20("GovToken", "GT") ERC20Permit("GovToken") {
        _mint(msg.sender, 100_000e18);
    }

    // This resolves the _update conflict
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    // This resolves the nonces conflict
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}

contract SenateTest is Test {
    Senate public governor;
    TimelockController public timelock;
    GovernanceToken public token;

    address public proposer = address(0x1);
    address public voter = address(0x2);
    address[] public proposers;
    address[] public executors;

    uint256 public constant QUORUM_PERCENT = 4;
    uint256 public constant VOTING_DELAY = 7200; // blocks
    uint256 public constant VOTING_PERIOD = 50400; // blocks
    uint256 public constant THRESHOLD = 500e18;

    function setUp() public {
        token = new GovernanceToken();

        // Setup Timelock
        proposers.push(address(0)); // Anyone can propose to timelock (we'll restrict via Governor)
        executors.push(address(0)); // Anyone can execute from timelock
        timelock = new TimelockController(86400, proposers, executors, address(this));

        governor = new Senate(token, timelock);

        // Grant roles to Governor
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        // Fund accounts and delegate
        token.transfer(proposer, 1000e18); // Above threshold
        token.transfer(voter, 10000e18); // For quorum
        token.transfer(address(timelock), 1000e18);

        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter);
        token.delegate(voter);

        vm.roll(block.number + 1); // Let delegation take effect
    }

    // --- View Function Overrides (Branch Coverage) ---

    function testGovernanceParameters() public view {
        assertEq(governor.proposalThreshold(), THRESHOLD);
        assertEq(governor.votingDelay(), VOTING_DELAY);
        assertEq(governor.votingPeriod(), VOTING_PERIOD);
        assertEq(governor.quorumNumerator(), QUORUM_PERCENT);
    }

    // --- The Full Happy Path (Proposal Lifecycle) ---

    function testFullProposalLifecycle() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        string memory description = "Proposal #1";

        targets[0] = address(token);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(ERC20.transfer.selector, address(0x123), 100e18);

        // 1. Propose
        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Pending));

        // 2. Wait for Voting Delay
        vm.roll(block.number + VOTING_DELAY + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Active));

        // 3. Vote
        vm.prank(voter);
        governor.castVote(proposalId, 1); // 1 = For

        // 4. Wait for Voting Period to end
        vm.roll(block.number + VOTING_PERIOD + 1);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Succeeded));

        // 5. Queue
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Queued));

        // 6. Execute
        vm.warp(block.timestamp + 86400 + 1); // Move past timelock delay
        governor.execute(targets, values, calldatas, descriptionHash);
        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Executed));
    }

    // --- Cancellation Logic ---

    function testProposalCanBeCancelledByProposer() public {
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        string memory description = "Cancel Me";

        targets[0] = address(0x123);
        values[0] = 0;
        calldatas[0] = "";

        vm.prank(proposer);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        // Cancel via proposer (GovernorStorage allows this)
        bytes32 descriptionHash = keccak256(bytes(description));
        vm.prank(proposer);
        governor.cancel(targets, values, calldatas, descriptionHash);

        assertEq(uint8(governor.state(proposalId)), uint8(IGovernor.ProposalState.Canceled));
    }

    // --- Internal & Edge Cases ---

    function testProposalAlwaysQueues() public view {
        // GovernorTimelockControl always returns true
        uint256 dummyId = 123;
        assertTrue(governor.proposalNeedsQueuing(dummyId));
    }

    function testTimelockIsTheExecutor() public view {
        assertEq(address(governor.timelock()), address(timelock));
    }
}
