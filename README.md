# Checkin / CHKN

A Sepolia test toy for organiser-authorised event attendance and optional CHKN rewards. **Attendance records are not tickets or credentials.** Records are public, permanent and non-transferable; possession of an address or signed pass does not establish a real-world identity or physical attendance.

This repository delivers the contract implementation, vendored dependencies, tests and ABI exports for the contract stage. The separate manifest contributor produces `launch.json`; independent review inspects the accepted source and manifest. Services then publish source, attest, admit and deploy through ProjectFactory before the frontend stage. No deployment has been made by this assignment.

## Build and check

Requires Foundry and Solidity **0.8.26**, pinned by version in `foundry.toml`. The compiler must be available locally for an offline build. All Solidity dependencies are ordinary files under `lib/`; no dependency download, submodule, environment variable, FFI or filesystem cheatcode permission is needed.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

After changing a public interface, run `python3 scripts/export_abis.py` to regenerate [LaunchToken ABI](docs/abi/LaunchToken.json) and [EventCheckin ABI](docs/abi/EventCheckin.json). The script uses Python's standard library and `forge inspect`.

Dependencies are OpenZeppelin Contracts v5.0.2 (the unmodified transitive subset used here) and forge-std v1.9.6 (test sources), with their licenses. [Archive URLs and SHA-256 hashes](docs/dependencies.json) identify the vendored releases. OpenZeppelin's [EIP712](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/EIP712.sol), [SignatureChecker](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.2/contracts/utils/cryptography/SignatureChecker.sol), SafeERC20 and ReentrancyGuard are used directly.

## Deployment parameters

| Item | Required value |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Project kind / site label | `evm_project` / `lab-event-checkin` |
| Launch token | `src/LaunchToken.sol:LaunchToken` |
| Token constructor | No arguments; nonpayable |
| Token metadata | `Checkin`, `CHKN`, 18 decimals |
| Total supply | `1000000000000000000000000000` base units, minted once to the constructor caller |
| Application | `src/EventCheckin.sol:EventCheckin` |
| Application constructor | One `address token_`; nonpayable; manifest `constructorArgs: ["$token"]` |
| Deployment order | LaunchToken, then EventCheckin using that token address |
| Compiler | Solidity `0.8.26`, optimizer 200 runs, Cancun EVM, `bytecode_hash = "none"` |
| Application initial funding | Zero; no approval, allocation, initialization call or ETH required |
| Privileged deployment arguments | None; there is no owner or global administrator |

The factory receives the entire token supply and services handle LP/reward distribution. EventCheckin's constructor only checks that the token address is nonzero and has code, then stores it immutable. It does not authenticate arbitrary ERC-20 implementations: the manifest and independent reviewer must ensure this argument is the deployed LaunchToken. Neither constructor depends on a particular deploying wallet. Factory execution does not make the factory an application administrator. No proxy, upgrade path, external oracle, randomness, keeper or payable entry point is used.

Sepolia is the authorised deployment and frontend network. The contracts do not hard-code a chain-ID deployment gate; the signature domain uses the actual chain ID, including after a fork. Services and the page must enforce Sepolia selection. Deployment addresses, deployment block and applicable protocol policy are provided by the later deployment services. Policy and signed-artifact linkage belong to those services, rather than invented fields in this contribution.

## Event lifecycle and funds

1. Anyone calls `createEvent(title, endsAt, rewardPerCheckIn)`. The caller becomes that event's immutable organiser. IDs start at 1. `title` is opaque `bytes32` (the page can UTF-8 encode and zero-pad up to 32 bytes). `endsAt` must be strictly in the future and at most 365 days away. Rewards are integer CHKN base units; zero is valid.
2. Anyone can approve EventCheckin on CHKN, then call `fundEvent(id, amount)` with a positive amount while the event is open. **Funders trust the organiser**, who chooses whom to sign for and may close the event and reclaim all unspent donations. A funder has no refund claim. Each event has its own pool.
3. The organiser signs the exact [EIP-712 pass](docs/ABI.md). Anyone can submit it. The attendee must be nonzero, the event must be open, and the attendee must not already have checked in. Deadline and event end are inclusive: submissions at exactly either timestamp are allowed. Successful attendance consumes that event/attendee pair permanently.
4. If that event's pool covers the entire configured reward, the reward moves to the **attendee's** withdrawable credit. Otherwise attendance is still recorded, with reward zero and the pool unchanged. Rewards are not partial or retroactive; funding later cannot reward an already recorded check-in. A relayer receives no credit. Transaction ordering can determine which valid passes receive the remaining rewards.
5. Only the organiser can close an event, irreversibly. Closure immediately stops both funding and check-ins. Expiry also stops both after `endsAt`, without a maintenance transaction. A second explicit close reverts.
6. Only the organiser can `reclaim` after closure or strictly after expiry. This moves the unspent pool into the organiser's withdrawable credit. Repeating reclaim emits a zero amount and transfers no additional credit. Already accrued attendee rewards remain theirs.
7. Each credited account calls `withdraw()` to transfer its full balance to itself. Credit is cleared before the external SafeERC20 transfer, under a reentrancy guard. A failed transfer reverts the transaction and restores credit. Zero-credit withdrawals revert. There is no withdrawal deadline and no operator that can redirect another account's funds.

The conservation identity is `CHKN held = sum(event pools) + sum(withdrawable credits)` for CHKN entering through `fundEvent`. Unit tests and a stateful invariant exercise this identity across events and actors. The invariant uses an independent model of intended operations and checks individual pools, credits and attendance as well as aggregate balances.

An ERC-20 holder can transfer CHKN directly to any address, bypassing the recipient's API. Direct transfers to EventCheckin do **not** fund a pool or create credit; they become stranded surplus. With such transfers the identity becomes `held = liabilities + surplus`, and solvency remains `held >= liabilities`. There is deliberately no sweep/admin function. Use approve + `fundEvent`. Only the fixed, non-rebasing, fee-free LaunchToken is supported; exact received-amount checking rejects taxed funding, but is not a claim of support for arbitrary tokens. No native ETH is accepted through normal calls, and forcibly sent native ETH has no recovery function.

## Signatures and operational responsibilities

The domain is `{name: "EventCheckin", version: "1", chainId, verifyingContract}`. The signed type is exactly `CheckIn(uint256 eventId,address attendee,uint256 deadline)`; `CheckIn` has a capital `I`. Domain literals are in the EIP712 base-constructor call. Ordinary EOA passes are 65-byte `r || s || v` signatures; OpenZeppelin rejects high-s signatures. The pass binds event, attendee, deadline, chain and deployment. Replay protection is the permanent attendance record for each event/attendee pair, not a separate nonce.

The application has no individual-pass revocation method. An EOA organiser can stop a previously signed unused pass by closing the event or waiting for its deadline/event expiry. For ERC-1271 organisers, validity additionally follows the contract wallet's current signature policy, which can change or revoke acceptance. Validation happens via `staticcall`; rejecting, reverting, malformed or gas-consuming wallets can fail their own submissions but do not create shared settlement queues or prevent other events from operating. Relayers should simulate contract-wallet submissions and set gas limits. An ERC-1271 organiser wallet must also be able to invoke create/close/reclaim/withdraw itself to exercise those powers.

The later one-page website must:

- Connect only to Sepolia, read CHKN from `EventCheckin.token()`, and show balance, allowance and withdrawable credit. Present an Approve step before funding.
- Offer organiser create/fund/close/reclaim actions and EOA `eth_signTypedData_v4` pass creation using the exact type in `docs/ABI.md`. Show a copyable pass and a link carrying `eventId`, `attendee`, `deadline`, `signature`; treat imported links as untrusted until checked against the selected deployment.
- Offer attendee pass import, relayed check-in and caller withdrawal. Distinguish recorded attendance from an awarded reward. Show each event's attendee list from indexed `CheckedIn` logs.
- Query only contract views and events, chunking log queries from the service-supplied deployment block; deduplicate by transaction hash/log index and handle reorganisations. There is no backend or indexer in the approved design.
- Say CHKN comes from swapping Sepolia ETH in the launch pool, with no in-page swap. Clearly state that this is a Sepolia test toy and attendance records are not tickets or credentials. Publish the later static export with `dist/index.html` and site label `lab-event-checkin`.

The separate independent contributor must review source **and the concrete generated manifest**, including constructor/token linkage, before release. Services own publication, attestations, admission, policy resolution, deployment and live addresses. Website work begins against that live deployment. Tests and the [review handoff](docs/REVIEW.md) are implementation evidence, not an independent security audit.

## Test coverage

The suite covers token supply and transfers, factory-style CREATE2 deployment, runtime size/opcodes, all lifecycle transitions, inclusive time boundaries, zero/invalid actions, relayer attribution, underfunded rewards, pool isolation, reclaim/check-in ordering, failed withdrawals, token-call reentrancy, and direct-transfer surplus. Signature tests cover independent domain/type encoding, wrong signer/event/attendee/deadline/name/version/chain/deployment, fork replay, high-s/invalid-v/malformed signatures, duplicate passes, and ERC-1271 acceptance, rejection, reversion, short replies, gas griefing and attempted state mutation.

Default fuzzing runs 256 cases per parameterized test. The stateful invariant runs 128 sequences of 64 calls and uses six participants, multiple organisers, dynamically created events, funding, check-in, closure, reclaim, withdrawal and time advancement. Tests configure their own chain/time and use deterministic test-only signing keys; no environment values, wallet access, RPC endpoints or broadcast are needed.
