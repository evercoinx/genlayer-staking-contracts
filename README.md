# GenLayer Staking Contracts

A simplified optimistic consensus mechanism implementation inspired by GenLayer's architecture, featuring validator staking, proposal management, LLM-based validation simulation, and dispute resolution.

## Overview

This project implements a decentralized consensus system where validators stake GLT tokens to participate in proposal validation. The system uses an optimistic approach with challenge windows and includes a mock LLM oracle for deterministic validation in testing environments.

## Architecture

### Core Components

1. **GLTToken** - ERC20 token used for staking (max supply: 1 billion)
2. **ValidatorRegistry** - Manages validator registration, staking, and slashing
3. **ProposalManager** - Handles proposal lifecycle and state transitions
4. **MockLLMOracle** - Simulates LLM validation with deterministic logic
5. **ConsensusEngine** - Orchestrates voting rounds and consensus finalization
6. **DisputeResolver** - Manages challenges, dispute voting, and reward distribution

### Key Features

- **Validator Staking**: Minimum 1000 GLT tokens required
- **Optimistic Consensus**: 10-block challenge window for proposals
- **Dispute Resolution**: 10% slash penalty for false challenges
- **Mock LLM Validation**: Even hashes = valid, odd hashes = invalid
- **Signature Validation**: ECDSA signatures for all validator actions
- **Maximum 100 Active Validators**: Selected by highest stake

## Contract Interactions

```
┌─────────────┐      ┌───────────────────┐      ┌─────────────────┐
│  GLTToken   │────▶│ ValidatorRegistry │◀────│ ProposalManager │
└─────────────┘      └───────────────────┘      └─────────────────┘
                             │                         │
                             ▼                         ▼
                    ┌─────────────────┐       ┌──────────────┐
                    │ ConsensusEngine │       │ MockLLMOracle│
                    └─────────────────┘       └──────────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │ DisputeResolver │
                    └─────────────────┘
```

## Installation

```bash
# Clone the repository
git clone <repository-url>
cd genlayer-staking-contracts

# Install dependencies
forge install

# Build contracts
forge build
```

## Testing

```bash
# Run all tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run tests with coverage
forge coverage

# Run specific test contract
forge test --match-contract GLTTokenTest -vvv
```

## Deployment

1. Set up environment variables:

```bash
export PRIVATE_KEY=<your-private-key>
export RPC_URL=<your-rpc-url>
```

2. Deploy contracts:

```bash
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

3. Verify deployment:

```bash
forge verify-contract <contract-address> <contract-name> --chain <chain-id>
```

## Usage Examples

### 1. Register as Validator

```solidity
// Approve GLT tokens
gltToken.approve(address(validatorRegistry), 2000e18);

// Register with 2000 GLT stake
validatorRegistry.registerValidator(2000e18);
```

### 2. Create Proposal

```solidity
// Only active validators can create proposals
bytes32 contentHash = keccak256("proposal content");
uint256 proposalId = proposalManager.createProposal(contentHash, "Proposal metadata");
```

### 3. Challenge Proposal

```solidity
// During challenge window (10 blocks)
proposalManager.challengeProposal(proposalId);

// Create dispute with stake
gltToken.approve(address(disputeResolver), 100e18);
uint256 disputeId = disputeResolver.createDispute(proposalId, 100e18);
```

### 4. Vote on Dispute

```solidity
// Validators vote on dispute
bytes memory signature = signDisputeVote(disputeId, true);
disputeResolver.voteOnDispute(disputeId, true, signature);
```

## Security Considerations

1. **Reentrancy Protection**: All state-changing functions use OpenZeppelin's ReentrancyGuard
2. **Access Control**: Role-based permissions for critical functions
3. **Integer Overflow**: Built-in Solidity 0.8.x overflow protection
4. **Signature Validation**: ECDSA signatures required for validator actions
5. **Time-based Attacks**: Block number used instead of timestamp for challenge windows

## Gas Optimization

- Struct packing for storage efficiency
- Mapping usage over arrays where possible
- Batch operations for multiple validations
- View functions for read-only operations

## Development Standards

- Solidity 0.8.28
- OpenZeppelin Contracts 5.x
- Custom errors for gas efficiency
- Comprehensive NatSpec documentation
- Interface-driven architecture
- Event emission for all state changes

## Testing Coverage Target

The project aims for >95% test coverage across all contracts:

- Unit tests for individual contract functions
- Integration tests for contract interactions
- Fuzz tests for edge cases
- Invariant tests for system properties

## License

MIT

## Acknowledgments

This implementation is inspired by GenLayer's optimistic consensus mechanism and is intended for educational and testing purposes.
