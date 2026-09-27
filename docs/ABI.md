# Contract ABI and signing integration

Machine-readable ABI arrays: [LaunchToken.json](abi/LaunchToken.json) and [EventCheckin.json](abi/EventCheckin.json). Regenerate using `python3 scripts/export_abis.py`; check freshness with `--check`. All amounts below are base units, where `10^18` units are one CHKN. Timestamps are Unix seconds, not milliseconds. Use bigint or decimal strings in clients; JavaScript numbers cannot represent arbitrary token amounts or uint256 fields safely.

## LaunchToken

`constructor()` is nonpayable. ERC-20 name `Checkin`, symbol `CHKN`, decimals `18`, fixed supply `10^27` minted to its deployer. Standard `balanceOf`, `totalSupply`, `transfer`, `allowance`, `approve` and `transferFrom`, with `Transfer` and `Approval` events. No public mint, burn, owner, pause, blacklist, fee-setting or upgrade functions.

## EventCheckin calls

`constructor(address token_)` is nonpayable. Pass the already deployed LaunchToken (`$token` in the separately generated manifest).

| Function | Caller and result |
| --- | --- |
| `createEvent(bytes32 title, uint64 endsAt, uint256 rewardPerCheckIn) returns (uint256 eventId)` | Any caller becomes organiser; returns the new ID. A transaction receipt supplies the ID through `EventCreated`. |
| `fundEvent(uint256 eventId, uint256 amount)` | Anyone, positive approved amount, open event. Requires CHKN allowance for EventCheckin. |
| `closeEvent(uint256 eventId)` | Event organiser only, once. |
| `checkIn(uint256 eventId, address attendee, uint256 deadline, bytes signature)` | Anyone may relay; attendance and any reward belong to attendee. |
| `reclaim(uint256 eventId)` | Organiser only, closed or expired event; pool becomes organiser credit. |
| `withdraw()` | Any credited account; transfers all its credit to itself. |

Every state-changing entry point is nonpayable and guarded against reentrancy. The contract has no receive/fallback entry point.

| View | Result |
| --- | --- |
| `token()` | Immutable CHKN address |
| `eventCount()` | Last assigned event ID; valid IDs are 1 through this value |
| `eventInfo(uint256 id)` | Seven flat outputs in order: `address organiser, bytes32 title, uint64 endsAt, bool closed, uint256 rewardPerCheckIn, uint256 pool, uint256 attendeeCount`; invalid IDs revert |
| `attended(uint256 eventId, address attendee)` | Permanent boolean; false for unrecorded/unknown pairs |
| `attendanceCount(address attendee)` | Total events attended |
| `withdrawable(address account)` | Combined credit across all events |
| `CHECKIN_TYPEHASH()` | `keccak256("CheckIn(uint256 eventId,address attendee,uint256 deadline)")` |
| `domainSeparator()` | EIP-712 domain separator for the current chain and this deployment |
| `eip712Domain()` | OpenZeppelin IERC-5267 domain discovery: fields `0x0f`, name, version, current chain ID, this address, zero salt, empty extensions |

## Typed data

This is the exact JSON shape for `eth_signTypedData_v4`. Replace the example verifying contract with the service-published EventCheckin address, and replace the example message with the selected event, attendee and deadline. These addresses and times are examples, not a deployment or usable pass.

```json
{
  "types": {
    "EIP712Domain": [
      {"name": "name", "type": "string"},
      {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"},
      {"name": "verifyingContract", "type": "address"}
    ],
    "CheckIn": [
      {"name": "eventId", "type": "uint256"},
      {"name": "attendee", "type": "address"},
      {"name": "deadline", "type": "uint256"}
    ]
  },
  "primaryType": "CheckIn",
  "domain": {
    "name": "EventCheckin",
    "version": "1",
    "chainId": 11155111,
    "verifyingContract": "0x1111111111111111111111111111111111111111"
  },
  "message": {
    "eventId": "1",
    "attendee": "0x000000000000000000000000000000000000cafe",
    "deadline": "1800000000"
  }
}
```

With an EIP-1193 provider, the later page submits:

```javascript
const signature = await provider.request({
  method: "eth_signTypedData_v4",
  params: [connectedOrganiser, JSON.stringify(typedData)]
});
```

Require the connected wallet address to equal `eventInfo(id).organiser` for the page's EOA signing flow. Contract wallets are supported on-chain and in the tests, but their signing workflow is not part of this page. Never sign the JSON text with `personal_sign`; do not substitute `Checkin`, `uint64 deadline`, `abi.encodePacked` struct fields, or a token address as the verifying contract.

The digest is:

```text
structHash = keccak256(abi.encode(CHECKIN_TYPEHASH, eventId, attendee, deadline))
digest     = keccak256(0x1901 || domainSeparator || structHash)
```

The `deadline` field has type uint256 even though the event's stored `endsAt` has type uint64. A deadline after event end is permitted, but never extends the event. No submitter, reward, nonce, title or token field belongs in the signed message.

Copyable pass/link payload: decimal-string `eventId`, address `attendee`, decimal-string `deadline`, hex `signature`. The page's configured chain and EventCheckin address supply domain context. Opening a pass should display the target event/attendee and require an explicit check-in action. The submitter may differ from the attendee. Read `CheckedIn.reward` to determine the actual award; it may be zero despite a positive configured reward.

## Events

| Event | Indexed fields | Other fields |
| --- | --- | --- |
| `EventCreated` | `uint256 eventId`, `address organiser` | `bytes32 title`, `uint64 endsAt`, `uint256 rewardPerCheckIn` |
| `EventFunded` | `uint256 eventId`, `address funder` | `uint256 amount` |
| `EventClosed` | `uint256 eventId` | None |
| `CheckedIn` | `uint256 eventId`, `address attendee`, `address submitter` | `uint256 reward` |
| `Reclaimed` | `uint256 eventId`, `address organiser` | `uint256 amount` (possibly zero on repeats) |
| `Withdrawn` | `address account` | `uint256 amount` |

Query `CheckedIn` by indexed event ID to list attendees, using chunked RPC ranges from the deployment block. There is no unbounded on-chain list getter. Zero-reward check-ins still emit and belong in the attendee list. Reclaim emits a credit movement, not a token transfer; `Withdrawn` accompanies the actual outgoing ERC-20 transfer.

## Failures

Application errors are `InvalidToken`, `InvalidEndTime`, `UnknownEvent`, `EventNotOpen`, `NotOrganiser`, `AlreadyClosed`, `InvalidAmount`, `UnexpectedTokenAmount`, `InvalidAttendee`, `PassExpired`, `AlreadyAttended`, `InvalidSignature`, `EventStillOpen` and `NothingToWithdraw` (all no-argument errors). SafeERC20, ERC-20 and ReentrancyGuard errors may also propagate; their relevant ABI entries are included in the exports. `InvalidSignature` covers ordinary invalid EOA and ERC-1271 responses; an ERC-1271 wallet that exhausts available gas can instead cause an out-of-gas failure. Failed transactions create no attendance or credit. Simulate before submitting and re-read state after confirmation.
