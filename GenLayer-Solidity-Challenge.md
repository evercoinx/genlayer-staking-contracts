# GenLayer Solidity Challenge: Implementing a Simplified Optimistic Consensus Mechanism for GenLayer-Inspired Intelligent Contracts

## Overview

GenLayer is a blockchain platform that enables Intelligent Contracts powered by Large Language Models (LLMs). This challenge requires implementing a simplified optimistic consensus mechanism inspired by GenLayer's architecture. The focus is on creating a staking system for validators, proposing transactions, validating them optimistically using a mock LLM, achieving consensus, and handling disputes. This simulates how GenLayer uses LLMs for transaction validation in an optimistic manner, with fallback to consensus if challenged.

## Requirements

### Language and Tools
- Solidity (v0.8.x), with testing in Foundry (preferred for fuzz/invariant testing) or Hardhat.
- Use OpenZeppelin libraries where appropriate (e.g., for ERC20 tokens or access control).

### Core Features to Implement

#### 1. Validator Staking and Selection
- Create a staking contract where users can stake a mock ERC20 token (e.g., "GLT" for GenLayer Token) to become validators.
- When a new Validator is joined a Beacon proxy contract is created that keeps the validator stake and metadata of the validator.
- Selection for transaction executions:
  - Implement a simple dPoS-like selection: Select the top N validators (e.g., N=5) based on stake amount.
- Minimum stake: 1000 GLT. Validators can unstake after a bonding period (e.g., 1 block for simplicity).

#### 2. Transaction Proposal and Optimistic Execution
- Allow anyone to propose a simple "transaction" (e.g., a string message representing an Intelligent Contract call, like "Approve loan for user X based on LLM analysis").
- Optimistically "execute" the proposal by assuming it's valid unless challenged.
- Store proposals in a mapping with states: Proposed, OptimisticApproved, Challenged, Finalized.

#### 3. Mock LLM Validation and Consensus
- Simulate LLM input using a deterministic function or mock oracle (e.g., a function that hashes the proposal and returns "valid" or "invalid" based on even/odd hash).
- Validators must sign off on proposals using ECDSA signatures (via ecrecover).
- Require signatures from at least 3/5 validators for optimistic approval.
- If all selected validators agree (via signatures), finalize optimistically.

#### 4. Dispute Resolution
- Any validator can challenge a proposal within a window (e.g., 10 blocks).
- On challenge, trigger a vote: Validators submit votes (yes/no) with signatures.
- Resolve via majority: If >=50% vote to reject, revert the proposal; otherwise, finalize it.
- Penalize false challenges (slash 10% of challenger's stake) or reward honest ones (transfer slash to challenger).

#### 5. Security and Edge Cases
- Prevent reentrancy, overflow/underflow.
- Handle slashable offenses (e.g., invalid signatures).
- Emit events for all state changes (e.g., ProposalCreated, Validated, Challenged, Finalized).

## Assumptions/Simplifications
- No real LLM integration—use mocks.
- No cross-chain or full blockchain simulation; focus on contract logic.
- Use a single contract or a few modular ones (e.g., Staking.sol, Consensus.sol).
- Deploy on a testnet like Sepolia if you want, but local testing is fine.

## Deliverables

Submit a GitHub repo (public or shared link) with:

### 1. Source Code
All Solidity files.

### 2. Tests
- Unit tests (e.g., successful staking, proposal flow).
- Fuzz tests (e.g., random stakes, signatures) using Foundry's fuzzing or Hardhat's equivalent.
- Invariant tests (e.g., total stake never decreases unexpectedly).
- Aim for 80%+ coverage.

### 3. Documentation
- README explaining architecture, how to run/deploy/test.
- Inline comments in code.
- A short write-up (1-2 pages) on design choices, potential vulnerabilities mitigated, and how this could extend to GenLayer's AI consensus (e.g., replacing mock LLM with oracle calls).

## Optional Bonus
- Gas optimization report.
- Simple front-end (e.g., via ethers.js) to interact with the contract.

## Evaluation Criteria
- **Correctness (40%):** Does the contract work as specified? Handles happy paths and failures (e.g., invalid signatures, low stake).
- **Security (30%):** Evidence of best practices (e.g., checks-effects-interactions, audits via Slither/Mythril if used). Robust testing for exploits.
- **Design and Efficiency (20%):** Clean, modular code. Efficient data structures (e.g., no O(n^2) operations). Gas-aware.
- **Creativity and Insight (10%):** How well you tie it to GenLayer's optimistic/AI aspects in your write-up. Bonus for extensions like ZK proofs for votes.

Submit by the end of the weekend (e.g., Monday morning). Feel free to ask clarifying questions via email. Good luck—this will help us assess your fit for building consensus innovations at GenLayer!