# Commit-Reveal Voting with Delegation (Clarity)

A Clarity smart contract implementing a commit–reveal voting protocol with optional delegation. Voters first submit a hashed commitment of their vote during the commit phase, and later reveal the vote in the reveal phase. Delegation lets a voter assign their voting power to another principal.

This repository includes:
- contracts/CommitPool.clar – the smart contract
- tests/CommitPool.test.ts – TypeScript tests (Vitest + Clarinet SDK)
- Clarinet.toml – Clarinet project config
- settings/Devnet.toml – Local devnet configuration

Note: This README describes the patterns and interfaces typically used in this contract. Refer to the source for exact names/parameters.

## Features
- Commit–reveal mechanism to reduce bribery and herd effects
- Delegation of votes to another principal
- Strict phase enforcement (commit window -> reveal window)
- Hash-verified reveals to ensure vote integrity
- View functions for inspection of state (commitments, tallies, params)

## How it works
1. Initialization
   - The contract stores configuration such as commit-start, commit-end, reveal-end block heights (or timestamps), and the options that can be voted on.
2. Commit Phase
   - A voter (or a delegate on their behalf, depending on contract rules) submits a commitment: a hash computed from the vote choice, a secret (salt), and usually the voter principal to prevent front-running.
   - The contract records the commitment for the voter.
3. Delegation
   - A voter can delegate their voting power to another principal. The contract typically prevents delegation loops and may restrict redelegation timing.
4. Reveal Phase
   - The voter (or authorized delegate) reveals by submitting the vote choice and the secret. The contract recomputes the hash and verifies it matches the stored commitment.
   - If valid and not previously revealed, the vote is tallied (weighted if delegation is implemented as weight transfer).
5. Finalization
   - After the reveal window ends, results can be read from getters or finalized in a function that locks further state changes.

## Contract interface (typical)

The exact names may differ; check contracts/CommitPool.clar for the definitive interface.

Public functions (tx):
- commit(commitment: (buff or hex)) -> bool/ok
- reveal(choice: uint or ascii/utf8, secret: (buff or hex)) -> bool/ok
- delegate(to: principal) -> bool/ok
- undelegate() -> bool/ok
- init-params(...) -> bool/ok (if parameters are settable)

Read-only functions (views):
- get-commit(voter: principal) -> (optional commitment)
- get-delegate(voter: principal) -> (optional principal)
- get-phase() -> uint/enum (e.g., 0=before,1=commit,2=reveal,3=ended)
- get-tally() -> {option-a: uint, option-b: uint, ...} or list/map
- get-params() -> {commit-start, commit-end, reveal-end, ...}

Data maps/vars (conceptual):
- commitments: principal -> commitment-hash
- revealed: principal -> bool
- delegates: principal -> principal
- tallies: option-id -> uint
- params: { commit-start, commit-end, reveal-end, ... }

Events:
- committed(voter, commitment)
- revealed(voter, choice)
- delegated(from, to)
- undelegated(from)

## Commitment format

A common pattern is:

commitment = hash256( concat( voter-principal-bytes, choice-bytes, secret-bytes ) )

- Including the voter principal reduces replay/front-running.
- Exact encoding must match the contract implementation (e.g., serialization order, Buff sizes).

## Development

Prerequisites:
- Node.js (LTS recommended)
- Clarinet (Stacks Clarity dev tool)

Install dependencies:

- npm install

Run tests (Vitest):

- npm test

Or run Clarinet tests (if you add .clar tests):

- clarinet test

Start a devnet (if desired):

- clarinet integrate

## Testing

The tests/CommitPool.test.ts file demonstrates basic workflows:
- Phase gating: rejects commits outside commit window and reveals outside reveal window
- Commit and reveal: acceptance of valid reveals that match prior commitments
- Delegation: assigning a delegate and ensuring vote weight or authority is recognized
- Tally: computing or reading final vote counts after valid reveals
- Edge cases: double-commit prevention, double-reveal prevention, unchanged delegation, invalid hashes, etc.

Run:
- npm test

## Security considerations
- Phase enforcement: Only allow commits in commit window and reveals in reveal window.
- Hash binding: Bind commitment to voter principal and vote choice to prevent substitution and replay.
- Delegation safety: Prevent cycles, restrict changes after commits, and define when delegation is locked.
- Non-reveals: Decide whether non-revealed commitments are ignored or penalized.
- Idempotency: Block double commits or double reveals, or define overwrite rules clearly.
- Reentrancy: Clarity is non-reentrant, but still validate external-call safety if any.
- Access control: Only contract owner/admin (if any) should set/modify parameters where applicable.

## Deployment

Using Clarinet console or a deployment pipeline:
1. Set desired parameters (windows, options) either at deployment or via an init function.
2. Deploy the contract (testnet/mainnet) from an admin account.
3. Verify the source and publish the contract ID for users.

## Usage example (conceptual)

1) Commit
- Call commit with a computed hash. Example pseudo-code:
  - secret = random 32 bytes
  - choice = 1
  - commit = hash256(encode(voter, choice, secret))
  - contract.commit(commit)

2) Reveal
- After commit phase ends and in reveal window:
  - contract.reveal(choice, secret)

3) Delegation
- Optional: before committing or per contract rules
  - contract.delegate(delegate-principal)

4) Read results
- contract.get-tally() or similar view to read current tallies.

## Repository structure
- contracts/CommitPool.clar
- tests/CommitPool.test.ts
- settings/Devnet.toml
- Clarinet.toml
- package.json, tsconfig.json, vitest.config.js

## Notes
- Always confirm the exact function names and types in contracts/CommitPool.clar.
- If you need a CLI helper for computing commitments in JavaScript/TypeScript, consider adding a small utility script that encodes (voter, choice, secret) exactly as the contract expects and outputs the commitment hash.

## License
Add a license of your choice (e.g., MIT) to the repository.
