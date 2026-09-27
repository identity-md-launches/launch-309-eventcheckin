# Independent review handoff

This is a builder's handoff, not an independent review or a release approval. The later reviewer must inspect accepted source together with the generated `launch.json`. No funded-wallet operations or deployment are part of this contribution.

## Concrete review targets

| Attack | Evidence and expected behavior |
| --- | --- |
| Wrong typed-data type/domain | `EventCheckinSignatures.t.sol` signs using independent literal encodings and tests wrong name, version, struct name, chain and verifying contract. Compare `docs/ABI.md` and the later site's actual `eth_signTypedData_v4` payload byte-for-byte in type names, order and field types. |
| Malleability / replay | High-s, bad-v, malformed, duplicate, changed-event, changed-attendee, changed-deadline, other-deployment and changed-chain cases must fail without consuming credit or attendance. A valid pass submitted by any relayer rewards only its attendee. |
| ERC-1271 griefing | Accept/reject/revert/short-response/gas-exhaustion/static-reentry mock modes are tested. Failure cannot consume the pass or affect other events. Wallet policy can revoke acceptance independently of event closure; relayers bear failed-transaction gas. |
| Organiser impersonation | Only the address that created the event controls close/reclaim and validates passes. A signer behind an ERC-1271 wallet is not itself the event organiser. There is no global role and no factory-derived owner. |
| Cross-event reward theft | An underfunded event stays unrewarded even when another event has tokens. The stateful model compares each event pool and each account credit, not only their sum. |
| Close/reclaim race | A check-in ordered before closure keeps its accrued reward; closure/reclaim ordered first prevents the check-in. Expiry is inclusive for check-in and exclusive for reclaim unless already closed. |
| Withdrawal / reentrancy | Credit is zeroed before transfer; failed transfers restore it. Fault-injection tests attempt recursive withdrawal both during incoming funding and outgoing withdrawal. |
| Constructor / manifest conflict | LaunchToken has no arguments and mints `10^27` to the factory. EventCheckin must receive exactly `$token`, with no allocation or initializer. Verify chain `11155111`, token identity/decimals/supply, and exactly one application. No `$owner` is required. |

## Limits and assumptions to preserve

- CHKN must be the fixed LaunchToken implementation. Constructor code-existence validation alone cannot establish this. Source/constructor/authorization mismatches in the concrete manifest remain review findings.
- Funders deliberately trust organisers. Closing early, selecting the organiser or friends as attendees, and reclaiming donations are authorised powers. The pass proves organiser consent, not attendance in the physical world.
- Direct ERC-20 donations bypass accounting and remain surplus, with no recovery authority. The equality invariant assumes funding via `fundEvent`; arbitrary donations change equality to solvency plus surplus. This constraint is demonstrated in a unit test and disclosed in the README.
- All six production mutations have a reentrancy guard. Signature validation is read-only. The production token has no receiver hooks. FaultToken and OrganiserWallet are test-only adversarial fixtures, not deployable dependencies.
- EOA pass cancellation is through closure/deadline/expiry only. ERC-1271 validation depends on the wallet's current policy. Contract-wallet signers and credited contract accounts must themselves be able to call application methods.
- Block timestamps define event/deadline boundaries; block producers can influence transaction ordering. There is no randomness, lottery or oracle claim.
- The suite validates locally with the pinned compiler; it does not verify live RPC behavior, a future website implementation, signed service artifacts or a concrete future launch manifest. Policy and signed-artifact linkage are service responsibilities under the canonical guidance.

## Local evidence

`forge build`, `forge test`, `forge fmt --check` and `python3 scripts/export_abis.py --check` are the reproducible checks. The deployment test uses CREATE2 with the real creation code and checks whole-supply preservation, zero application balance, bounded runtime and absence of DELEGATECALL, CALLCODE and SELFDESTRUCT. It is a baseline consistent with the supplied protected checks; the protected environment-driven service harness remains a separate check.

The tests need no network, environment variables, filesystem reads, FFI or test order. Defaults are 256 fuzz cases and 128 invariant runs at depth 64. The invariant starts with funded and underfunded events, recorded attendees and organiser credit, then exercises seven operation kinds against a separate model.
