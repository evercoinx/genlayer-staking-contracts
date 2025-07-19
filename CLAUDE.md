# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GenLayer Staking Contracts - A decentralized staking and governance system with optimistic consensus, validator management, and dispute resolution using GLT tokens.

## Essential Commands

### Development Commands
```bash
# Build contracts
forge build
forge compile --sizes  # Show contract sizes

# Run all tests
forge test

# Run specific test contract
forge test --match-contract <ContractName>Test -vvv

# Run single test function
forge test --match-test test_FunctionName -vvv

# Run tests with gas reporting
forge test --gas-report

# Run tests with coverage
forge coverage

# Format code
forge fmt

# Generate gas snapshot
forge snapshot --gas-report
```

### Deployment Commands
```bash
# Deploy to local network
make deploy-localhost

# Deploy to Base Sepolia
make deploy-base-sepolia

# Deploy with script directly
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# Required environment variables
export PRIVATE_KEY=<your-private-key>
export RPC_URL=<your-rpc-url>
export ALCHEMY_API_KEY=<your-alchemy-key>  # For Base networks
export ETHERSCAN_API_KEY=<your-etherscan-key>  # For verification
```

## Architecture & Contract Relationships

### Core Contract System
The system consists of 6 interconnected contracts that implement a complete governance and staking mechanism:

1. **GLTToken** → ValidatorRegistry
   - ERC20 token used for staking
   - ValidatorRegistry holds staked GLT tokens
   - DisputeResolver holds challenge stakes

2. **ValidatorRegistry** ← → ProposalManager
   - Maintains active validator set (max 100)
   - Only active validators can create proposals
   - DisputeResolver has slashing privileges

3. **ProposalManager** → MockLLMOracle
   - Manages proposal lifecycle: Pending → OptimisticApproved → Challenged → Finalized/Rejected
   - 10-block challenge window after optimistic approval
   - Integrates with LLM oracle for validation

4. **ConsensusEngine** ← → ProposalManager
   - Initiates voting rounds for challenged proposals
   - 100-block voting periods with 60% quorum requirement (3/5 validators)
   - Updates proposal state based on consensus outcome

5. **DisputeResolver** → ValidatorRegistry & ProposalManager
   - Handles challenges with minimum 100 GLT stake
   - 50-block dispute voting period
   - Can slash validators (10% penalty) via ValidatorRegistry
   - Note: Does not automatically reject proposals - requires separate ProposalManager action

### Key Design Patterns

**Optimistic Consensus Flow:**
1. Validator creates proposal → ProposalManager
2. Proposal gets optimistically approved (by authorized role)
3. 10-block challenge window opens
4. If challenged → ConsensusEngine initiates voting
5. If dispute created → DisputeResolver handles with stake at risk
6. Resolution updates validator stakes and proposal state

**Signature Verification:**
All validator actions require ECDSA signatures with specific message formats:
- Consensus votes: `"GenLayerConsensusVote" + roundId + validator + support + contractAddress + chainId`
- Dispute votes: `"GenLayerDisputeVote" + disputeId + validator + supportChallenge + contractAddress + chainId`

**Role-Based Access:**
- ValidatorRegistry: `slasher` role (assigned to DisputeResolver)
- ProposalManager: `proposalManager` role (for approvals/rejections)
- ConsensusEngine: `consensusInitiator` role (for starting rounds)

## Contract Constants

### Staking Parameters
- Minimum validator stake: 1000 GLT
- Maximum active validators: 100
- Unbonding period: 7 days
- Slash percentage: 10%

### Governance Parameters
- Challenge window: 10 blocks
- Consensus voting period: 100 blocks
- Consensus quorum: 60% (3/5 validators)
- Dispute voting period: 50 blocks
- Minimum challenge stake: 100 GLT

### Token Parameters
- GLT max supply: 1 billion tokens
- Initial deployment mint: 100 million tokens

## Testing Approach

The codebase includes 165 comprehensive unit tests covering:
- State transitions and access control
- Edge cases and reverting conditions
- Signature verification
- Economic mechanics (staking, slashing, rewards)
- Fuzz tests for parameter validation

Test files follow the pattern: `test/unit/<ContractName>.t.sol`

## Known Design Decisions

1. **DisputeResolver doesn't auto-reject proposals** - This is intentional to separate concerns. Proposal rejection must be handled by the ProposalManager role.

2. **Slashed tokens remain in ValidatorRegistry** - When validators are slashed, tokens stay in the registry contract rather than being transferred to the challenger.

3. **Mock LLM Oracle uses deterministic validation** - Even content hashes validate as true, odd as false. This is for testing only.

4. **Block-based timing** - Uses block numbers instead of timestamps to prevent manipulation.

5. **Single-threaded consensus** - Only one proposal can be in consensus voting at a time per proposal.