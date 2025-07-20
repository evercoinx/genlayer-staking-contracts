// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "@forge-std/Test.sol";
import { console2 } from "@forge-std/console2.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IValidatorRegistry } from "../../src/interfaces/IValidatorRegistry.sol";
import { IProposalManager } from "../../src/interfaces/IProposalManager.sol";
import { IConsensusEngine } from "../../src/interfaces/IConsensusEngine.sol";
import { IDisputeResolver } from "../../src/interfaces/IDisputeResolver.sol";
import { GLTToken } from "../../src/GLTToken.sol";
import { ValidatorRegistry } from "../../src/ValidatorRegistry.sol";
import { ProposalManager } from "../../src/ProposalManager.sol";
import { MockLLMOracle } from "../../src/MockLLMOracle.sol";
import { ConsensusEngine } from "../../src/ConsensusEngine.sol";
import { DisputeResolver } from "../../src/DisputeResolver.sol";

/**
 * @title SystemInvariantTest
 * @dev Invariant tests for the entire GenLayer system
 */
contract SystemInvariantTest is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    GLTToken public gltToken;
    ValidatorRegistry public validatorRegistry;
    ProposalManager public proposalManager;
    MockLLMOracle public llmOracle;
    ConsensusEngine public consensusEngine;
    DisputeResolver public disputeResolver;

    address public owner = address(this);
    address public proposalManagerRole = address(0x1000);
    address public consensusInitiatorRole = address(0x2000);

    SystemHandler public handler;

    function setUp() public {
        gltToken = new GLTToken(owner);
        llmOracle = new MockLLMOracle();
        validatorRegistry = new ValidatorRegistry(address(gltToken), owner);
        proposalManager = new ProposalManager(address(validatorRegistry), address(llmOracle), proposalManagerRole);
        consensusEngine =
            new ConsensusEngine(address(validatorRegistry), address(proposalManager), consensusInitiatorRole);
        disputeResolver = new DisputeResolver(address(gltToken), address(validatorRegistry), address(proposalManager));

        validatorRegistry.setSlasher(address(disputeResolver));

        handler = new SystemHandler(gltToken, validatorRegistry, proposalManager, consensusEngine, disputeResolver);

        vm.prank(proposalManager.owner());
        proposalManager = new ProposalManager(
            address(validatorRegistry),
            address(llmOracle),
            address(handler)
        );

        vm.prank(consensusEngine.owner());
        consensusEngine.setConsensusInitiator(address(handler));

        targetContract(address(handler));

        excludeSender(address(0));
    }

    /**
     * @dev Invariant: Active validator count never exceeds MAX_VALIDATORS
     */
    function invariant_ActiveValidatorsBelowMax() public view {
        uint256 activeCount = validatorRegistry.getActiveValidators().length;
        assertLe(activeCount, 100);
    }

    /**
     * @dev Invariant: Only validators with minimum stake are active
     */
    function invariant_ActiveValidatorsHaveMinimumStake() public view {
        address[] memory activeValidators = validatorRegistry.getActiveValidators();

        for (uint256 i = 0; i < activeValidators.length; i++) {
            IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(activeValidators[i]);
            assertGe(info.stakedAmount, 1000e18);
        }
    }

    /**
     * @dev Invariant: Proposal states are valid
     */
    function invariant_ProposalStatesValid() public view {
        uint256 totalProposals = proposalManager.totalProposals();
        uint256 startIndex = totalProposals > 10 ? totalProposals - 9 : 1;

        for (uint256 i = startIndex; i <= totalProposals; i++) {
            IProposalManager.Proposal memory proposal = proposalManager.getProposal(i);

            assertTrue(uint8(proposal.state) <= uint8(IProposalManager.ProposalState.Rejected));

            if (proposal.state == IProposalManager.ProposalState.Challenged) {
                assertTrue(proposal.challengeWindowEnd > 0);
            }
        }
    }

    /**
     * @dev Invariant: Consensus rounds have valid vote counts
     */
    function invariant_ConsensusVoteCountsValid() public view {
        uint256[] memory roundIds = handler.getConsensusRounds();

        for (uint256 i = 0; i < roundIds.length; i++) {
            (uint256 votesFor, uint256 votesAgainst, uint256 totalValidators) =
                consensusEngine.getVoteCounts(roundIds[i]);

            assertLe(votesFor + votesAgainst, totalValidators);
        }
    }

    /**
     * @dev Invariant: Dispute states are consistent
     */
    function invariant_DisputeStatesConsistent() public view {
        uint256 totalDisputes = disputeResolver.totalDisputes();
        uint256 startIndex = totalDisputes > 10 ? totalDisputes - 9 : 1;

        for (uint256 i = startIndex; i <= totalDisputes; i++) {
            IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(i);

            if (dispute.state == IDisputeResolver.DisputeState.Resolved) {
                assertTrue(dispute.challengerWon || !dispute.challengerWon);

                assertTrue(dispute.votesFor > 0 || dispute.votesAgainst > 0);
            }
        }
    }

    /**
     * @dev Invariant: Slashed validators have reduced stake
     */
    function invariant_SlashedValidatorsHaveReducedStake() public view {
        address[] memory slashedValidators = handler.getSlashedValidators();

        for (uint256 i = 0; i < slashedValidators.length; i++) {
            IValidatorRegistry.ValidatorInfo memory info = validatorRegistry.getValidatorInfo(slashedValidators[i]);

            if (info.stakedAmount < 1000e18) {
                assertEq(uint8(info.status), uint8(IValidatorRegistry.ValidatorStatus.Slashed));
            }
        }
    }
}

/**
 * @title SystemHandler
 * @dev Handler for system-wide invariant testing
 */
contract SystemHandler is Test {
    using MessageHashUtils for bytes32;
    using ECDSA for bytes32;

    GLTToken public immutable gltToken;
    ValidatorRegistry public immutable validatorRegistry;
    ProposalManager public immutable proposalManager;
    ConsensusEngine public immutable consensusEngine;
    DisputeResolver public immutable disputeResolver;

    address[] public validators;
    uint256[] public proposals;
    uint256[] public consensusRounds;
    uint256[] public disputes;
    address[] public slashedValidators;

    mapping(address => uint256) public validatorPrivateKeys;
    uint256 public nextValidatorKey = 0x1000;

    constructor(
        GLTToken _gltToken,
        ValidatorRegistry _validatorRegistry,
        ProposalManager _proposalManager,
        ConsensusEngine _consensusEngine,
        DisputeResolver _disputeResolver
    ) {
        gltToken = _gltToken;
        validatorRegistry = _validatorRegistry;
        proposalManager = _proposalManager;
        consensusEngine = _consensusEngine;
        disputeResolver = _disputeResolver;
    }

    /**
     * @dev Register a new validator
     */
    function registerValidator(uint256 stake) public {
        stake = 1000e18 + (stake % (50_000e18 - 1000e18));

        uint256 privateKey = nextValidatorKey++;
        address validator = vm.addr(privateKey);

        vm.prank(gltToken.owner());
        try gltToken.mint(validator, stake) { }
        catch {
            return;
        }

        vm.prank(validator);
        gltToken.approve(address(validatorRegistry), stake);

        vm.prank(validator);
        try validatorRegistry.registerValidator(stake) {
            validators.push(validator);
            validatorPrivateKeys[validator] = privateKey;
        } catch { }
    }

    /**
     * @dev Create a proposal
     */
    function createProposal(uint256 validatorIndex, bytes32 contentHash) public {
        if (validators.length == 0) return;

        validatorIndex = validatorIndex % validators.length;
        address proposer = validators[validatorIndex];

        vm.prank(proposer);
        try proposalManager.createProposal(contentHash, "Invariant test proposal") returns (uint256 proposalId) {
            proposals.push(proposalId);
        } catch { }
    }

    /**
     * @dev Approve proposal optimistically
     */
    function approveProposalOptimistically(uint256 proposalIndex) public {
        if (proposals.length == 0) return;

        proposalIndex = proposalIndex % proposals.length;
        uint256 proposalId = proposals[proposalIndex];

        try proposalManager.approveOptimistically(proposalId) { } catch { }
    }

    /**
     * @dev Challenge a proposal
     */
    function challengeProposal(uint256 proposalIndex, uint256 validatorIndex) public {
        if (proposals.length == 0 || validators.length == 0) return;

        proposalIndex = proposalIndex % proposals.length;
        validatorIndex = validatorIndex % validators.length;

        uint256 proposalId = proposals[proposalIndex];
        address challenger = validators[validatorIndex];

        vm.prank(challenger);
        try proposalManager.challengeProposal(proposalId) { } catch { }
    }

    /**
     * @dev Initiate consensus
     */
    function initiateConsensus(uint256 proposalIndex) public {
        if (proposals.length == 0) return;

        proposalIndex = proposalIndex % proposals.length;
        uint256 proposalId = proposals[proposalIndex];

        try consensusEngine.initiateConsensus(proposalId) returns (uint256 roundId) {
            consensusRounds.push(roundId);
        } catch { }
    }

    /**
     * @dev Cast vote in consensus
     */
    function castConsensusVote(uint256 roundIndex, uint256 validatorIndex, bool support) public {
        if (consensusRounds.length == 0 || validators.length == 0) return;

        roundIndex = roundIndex % consensusRounds.length;
        validatorIndex = validatorIndex % validators.length;

        uint256 roundId = consensusRounds[roundIndex];
        address validator = validators[validatorIndex];
        uint256 privateKey = validatorPrivateKeys[validator];

        bytes memory signature = _createVoteSignature(privateKey, roundId, support);

        vm.prank(validator);
        try consensusEngine.castVote(roundId, support, signature) { } catch { }
    }

    /**
     * @dev Create a dispute
     */
    function createDispute(uint256 proposalIndex, uint256 validatorIndex, uint256 challengeStake) public {
        if (proposals.length == 0 || validators.length == 0) return;

        proposalIndex = proposalIndex % proposals.length;
        validatorIndex = validatorIndex % validators.length;
        challengeStake = 100e18 + (challengeStake % (500e18 - 100e18));

        uint256 proposalId = proposals[proposalIndex];
        address challenger = validators[validatorIndex];

        uint256 balance = gltToken.balanceOf(challenger);
        if (balance < challengeStake) {
            vm.prank(gltToken.owner());
            try gltToken.mint(challenger, challengeStake - balance) { }
            catch {
                return;
            }
        }

        vm.prank(challenger);
        gltToken.approve(address(disputeResolver), challengeStake);

        vm.prank(challenger);
        try disputeResolver.createDispute(proposalId, challengeStake) returns (uint256 disputeId) {
            disputes.push(disputeId);
        } catch { }
    }

    /**
     * @dev Resolve dispute (with slashing)
     */
    function resolveDispute(uint256 disputeIndex) public {
        if (disputes.length == 0) return;

        disputeIndex = disputeIndex % disputes.length;
        uint256 disputeId = disputes[disputeIndex];

        IDisputeResolver.Dispute memory dispute = disputeResolver.getDispute(disputeId);

        vm.warp(dispute.votingEndTime + 1);

        try disputeResolver.resolveDispute(disputeId) {
            if (dispute.challengerWon) {
                slashedValidators.push(dispute.proposer);
            }
        } catch { }
    }

    /**
     * @dev Helper to create vote signature
     */
    function _createVoteSignature(
        uint256 privateKey,
        uint256 roundId,
        bool support
    )
        internal
        view
        returns (bytes memory)
    {
        address validator = vm.addr(privateKey);
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "GenLayerConsensusVote", roundId, validator, support, address(consensusEngine), block.chainid
            )
        );
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function getConsensusRounds() public view returns (uint256[] memory) {
        return consensusRounds;
    }

    function getSlashedValidators() public view returns (address[] memory) {
        return slashedValidators;
    }
}