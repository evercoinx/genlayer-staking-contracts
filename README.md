# GenLayer Staking Contracts

A comprehensive implementation of a decentralized staking and governance system inspired by GenLayer's optimistic consensus mechanism, featuring validator management, proposal governance, LLM-based validation simulation, and dispute resolution.

## Overview

This project implements a sophisticated consensus system where validators stake GLT tokens to participate in decentralized governance. The system employs an optimistic consensus approach with challenge windows, incorporates a mock LLM oracle for validation, and uses a beacon proxy pattern for upgradeable validator contracts.

## Architecture

### System Overview

The GenLayer Staking Contracts consist of 7 interconnected smart contracts that work together to provide a complete staking and governance solution:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        GenLayer Staking System                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────┐    ┌───────────────────┐    ┌─────────────────┐         │
│  │   GLTToken   │───▶│ ValidatorRegistry │◀───│ ProposalManager │         │
│  │ (ERC20 Token)│    │  (Staking & Auth) │    │ (Proposal Mgmt) │         │
│  └──────────────┘    └───────────────────┘    └─────────────────┘         │
│         │                      │                         │                  │
│         │                      ▼                         ▼                  │
│         │            ┌─────────────────┐       ┌──────────────┐           │
│         │            │ ValidatorBeacon │       │ MockLLMOracle│           │
│         │            │ (Upgradeability)│       │ (Validation) │           │
│         │            └─────────────────┘       └──────────────┘           │
│         │                      │                         │                  │
│         │                      ▼                         ▼                  │
│         │            ┌─────────────────┐       ┌─────────────────┐        │
│         └───────────▶│ ConsensusEngine │◀─────▶│ DisputeResolver │        │
│                      │    (Voting)     │       │  (Challenges)   │        │
│                      └─────────────────┘       └─────────────────┘        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Components

1. **GLTToken** (ERC20)

   - Governance token with 1 billion max supply
   - Used for validator staking and dispute stakes
   - Initial mint of 100 million tokens on deployment

2. **ValidatorRegistry** (Staking Hub)

   - Manages validator registration and staking
   - Implements beacon proxy pattern for validator contracts
   - Maintains sorted list of top validators by stake
   - Handles slashing and stake management

3. **ValidatorBeacon** (Upgradeability)

   - Beacon contract for validator proxy implementation
   - Enables upgrading validator logic without affecting state
   - Controlled by ValidatorRegistry

4. **ProposalManager** (Governance)

   - Manages proposal lifecycle and state transitions
   - Implements optimistic approval with challenge windows
   - Integrates with LLM oracle for validation

5. **MockLLMOracle** (Validation)

   - Simulates AI-based proposal validation
   - Deterministic logic: even hashes = valid, odd = invalid
   - Supports batch validation operations

6. **ConsensusEngine** (Voting Mechanism)

   - Orchestrates voting rounds for challenged proposals
   - Requires 60% quorum from active validators
   - Uses ECDSA signatures for vote verification

7. **DisputeResolver** (Challenge System)
   - Handles proposal challenges and dispute resolution
   - Manages stake-based disputes with slashing
   - Distributes rewards/penalties based on outcomes

### Proposal Lifecycle

```
┌─────────────┐      ┌────────────────┐      ┌────────────┐      ┌───────────┐
│   Created   │────▶│ Optimistically │────▶│ Challenged │────▶│ Finalized │
│  (Pending)  │      │    Approved    │      │            │      │    OR     │
└─────────────┘      └────────────────┘      └────────────┘      │ Rejected  │
                            │                                    └───────────┘
                            │ (10 blocks)                              ▲
                            └──────────────────────────────────────────┘
                                    No Challenge → Auto-Finalize
```

### Validator State Machine

```
┌─────────────┐      ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│ Unregistered│────▶│ Registered  │────▶│   Active    │────▶│  Slashed/   │
│             │      │ (Staked)    │      │ (Top N)     │      │  Inactive   │
└─────────────┘      └─────────────┘      └─────────────┘      └─────────────┘
                           │                                         │
                           └─────────────────────────────────────────┘
                                      Unstake (1 block delay)
```

### Consensus Flow

```
                    ┌─────────────────────┐
                    │ Proposal Challenged │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │ Consensus Round     │
                    │ Initiated (100 blks)│
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │ Validators Submit   │
                    │ Signed Votes        │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │ 60% Quorum Check    │
                    └──────────┬──────────┘
                               ▼
                    ┌─────────────────────┐
                    │ Proposal Finalized  │
                    │ or Rejected         │
                    └─────────────────────┘
```

### Key Features

- **Validator Staking**: Minimum 1000 GLT tokens required
- **Optimistic Consensus**: 10-block challenge window for proposals
- **Dispute Resolution**: 10% slash penalty for false challenges
- **Mock LLM Validation**: Even hashes = valid, odd hashes = invalid
- **Signature Validation**: ECDSA signatures for all validator actions
- **Top-N Selection**: Configurable active validator set (default 5, max 100)
- **Beacon Proxy Pattern**: Upgradeable validator contracts

## Process Walkthroughs

### Complete Proposal Flow

1. **Proposal Creation**

   ```
   Validator (Top 5) → Creates Proposal → ProposalManager
                                         ↓
                                    Proposal ID Generated
                                    State: Pending
   ```

2. **Optimistic Approval**

   ```
   Authorized Role → Approves Proposal → State: OptimisticApproved
                                        ↓
                                   10-block Challenge Window Opens
   ```

3. **Challenge Path (if disputed)**

   ```
   Any Validator → Challenges → ConsensusEngine Initiates Voting
                               ↓
                          100-block Voting Period
                               ↓
                          Validators Submit Signed Votes
                               ↓
                          60% Quorum Check → Finalized/Rejected
   ```

4. **Dispute Resolution (if challenged)**
   ```
   Challenger Stakes 100 GLT → DisputeResolver Creates Dispute
                               ↓
                          50-block Dispute Voting
                               ↓
                          Majority Vote → Slash/Reward Distribution
   ```

### Validator Registration Process

1. **Initial Registration**

   - Approve ValidatorRegistry to spend GLT tokens
   - Call `registerValidator()` with minimum 1000 GLT
   - Beacon proxy contract created for validator
   - Validator added to sorted stake list

2. **Becoming Active**

   - Automatic selection if in top N validators by stake
   - Can create proposals and participate in consensus
   - Eligible for dispute voting

3. **Stake Management**
   - Add stake: `addStake()` to improve ranking
   - Unstake: `unstake()` with 1-block delay
   - Slashing: 10% penalty for losing disputes

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

The project includes comprehensive test coverage with 241 test functions across 16 test files:

```bash
# Run all tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run tests with coverage
forge coverage

# Run specific test contract
forge test --match-contract GLTTokenTest -vvv

# Run integration tests
forge test --match-contract Integration -vvv

# Run fuzz tests with more runs
forge test --match-test testFuzz -vvv --fuzz-runs 1000
```

## Deployment

1. Set up environment variables:

```bash
export PRIVATE_KEY=<your-private-key>
export RPC_URL=<your-rpc-url>
export ETHERSCAN_API_KEY=<your-etherscan-key>  # For verification
```

2. Deploy contracts:

```bash
# Deploy to local network
make deploy-localhost

# Deploy to Base Sepolia
make deploy-base-sepolia

# Or use script directly
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

// Register with metadata
validatorRegistry.registerValidatorWithMetadata(
    2000e18,
    "Validator Name",
    "https://validator.example.com"
);
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

### 4. Vote on Consensus

```solidity
// Generate signature for consensus vote
bytes32 messageHash = keccak256(abi.encodePacked(
    "GenLayerConsensusVote",
    roundId,
    validator,
    support,
    address(consensusEngine),
    block.chainid
));
bytes memory signature = signMessage(messageHash);

// Submit vote
consensusEngine.submitVote(roundId, support, signature);
```

### 5. Vote on Dispute

```solidity
// Generate signature for dispute vote
bytes32 messageHash = keccak256(abi.encodePacked(
    "GenLayerDisputeVote",
    disputeId,
    validator,
    supportChallenge,
    address(disputeResolver),
    block.chainid
));
bytes memory signature = signMessage(messageHash);

// Submit vote
disputeResolver.voteOnDispute(disputeId, supportChallenge, signature);
```

## Security Considerations

1. **Reentrancy Protection**: All state-changing functions use OpenZeppelin's ReentrancyGuard
2. **Access Control**: Role-based permissions for critical functions
3. **Integer Overflow**: Built-in Solidity 0.8.x overflow protection
4. **Signature Validation**: ECDSA signatures required for validator actions
5. **Time-based Attacks**: Block number used instead of timestamp for challenge windows
6. **Front-running Protection**: Commit-reveal pattern for sensitive operations

## Gas Optimization

- Struct packing for storage efficiency
- Mapping usage over arrays where possible
- Batch operations for multiple validations
- View functions for read-only operations
- Custom errors instead of require strings
- Efficient sorting algorithms for validator rankings

## Development Standards

- Solidity 0.8.28
- OpenZeppelin Contracts 5.x
- Custom errors for gas efficiency
- Comprehensive NatSpec documentation
- Interface-driven architecture
- Event emission for all state changes
- Beacon proxy pattern for upgradeability

## Testing Coverage

The project maintains high test coverage with:

- **241 test functions** across **16 test files**
- Unit tests for individual contract functions
- Integration tests for contract interactions
- Fuzz tests for edge cases and random inputs
- Invariant tests for system properties
- Signature verification tests
- Access control tests
- State transition tests

## License

MIT

## Acknowledgments

This implementation is inspired by GenLayer's optimistic consensus mechanism and is intended for educational and testing purposes.
