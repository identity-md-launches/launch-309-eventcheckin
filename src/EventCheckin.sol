// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Soulbound attendance records and optional CHKN rewards. Sepolia test toy, not credentials or tickets.
/// @dev Deploy with LaunchToken. Funders trust each event's organiser to choose attendees and reclaim unspent funds.
contract EventCheckin is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct EventData {
        address organiser;
        bytes32 title;
        uint64 endsAt;
        bool closed;
        uint256 rewardPerCheckIn;
        uint256 pool;
        uint256 attendeeCount;
    }

    error InvalidToken();
    error InvalidEndTime();
    error UnknownEvent();
    error EventNotOpen();
    error NotOrganiser();
    error AlreadyClosed();
    error InvalidAmount();
    error UnexpectedTokenAmount();
    error InvalidAttendee();
    error PassExpired();
    error AlreadyAttended();
    error InvalidSignature();
    error EventStillOpen();
    error NothingToWithdraw();

    event EventCreated(
        uint256 indexed eventId, address indexed organiser, bytes32 title, uint64 endsAt, uint256 rewardPerCheckIn
    );
    event EventFunded(uint256 indexed eventId, address indexed funder, uint256 amount);
    event EventClosed(uint256 indexed eventId);
    event CheckedIn(uint256 indexed eventId, address indexed attendee, address indexed submitter, uint256 reward);
    event Reclaimed(uint256 indexed eventId, address indexed organiser, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    bytes32 public constant CHECKIN_TYPEHASH = keccak256("CheckIn(uint256 eventId,address attendee,uint256 deadline)");

    IERC20 public immutable token;
    uint256 public eventCount;
    mapping(uint256 eventId => EventData) private _events;
    mapping(uint256 eventId => mapping(address attendee => bool)) public attended;
    mapping(address attendee => uint256) public attendanceCount;
    mapping(address account => uint256) public withdrawable;

    /// @param token_ The already deployed CHKN contract; no funding or approvals are needed at deployment.
    constructor(address token_) EIP712("EventCheckin", "1") {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    function createEvent(bytes32 title, uint64 endsAt, uint256 rewardPerCheckIn)
        external
        nonReentrant
        returns (uint256 eventId)
    {
        if (endsAt <= block.timestamp || uint256(endsAt) > block.timestamp + 365 days) {
            revert InvalidEndTime();
        }
        eventId = ++eventCount;
        _events[eventId] = EventData(msg.sender, title, endsAt, false, rewardPerCheckIn, 0, 0);
        emit EventCreated(eventId, msg.sender, title, endsAt, rewardPerCheckIn);
    }

    /// @notice Donate to an open event. Unspent donations may be reclaimed by its organiser.
    function fundEvent(uint256 eventId, uint256 amount) external nonReentrant {
        EventData storage e = _event(eventId);
        _requireOpen(e);
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert UnexpectedTokenAmount();
        e.pool += amount;
        emit EventFunded(eventId, msg.sender, amount);
    }

    function closeEvent(uint256 eventId) external nonReentrant {
        EventData storage e = _event(eventId);
        if (msg.sender != e.organiser) revert NotOrganiser();
        if (e.closed) revert AlreadyClosed();
        e.closed = true;
        emit EventClosed(eventId);
    }

    /// @notice Submit an organiser's pass for an attendee; the submitter receives no attendance or reward.
    /// @dev A valid pass consumes this event/attendee pair even if the pool is too small to reward it.
    function checkIn(uint256 eventId, address attendee, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        EventData storage e = _event(eventId);
        _requireOpen(e);
        if (attendee == address(0)) revert InvalidAttendee();
        if (block.timestamp > deadline) revert PassExpired();
        if (attended[eventId][attendee]) revert AlreadyAttended();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CHECKIN_TYPEHASH, eventId, attendee, deadline)));
        if (!SignatureChecker.isValidSignatureNow(e.organiser, digest, signature)) revert InvalidSignature();

        attended[eventId][attendee] = true;
        ++attendanceCount[attendee];
        ++e.attendeeCount;
        uint256 reward = 0;
        if (e.pool >= e.rewardPerCheckIn) {
            reward = e.rewardPerCheckIn;
            e.pool -= reward;
            withdrawable[attendee] += reward;
        }
        emit CheckedIn(eventId, attendee, msg.sender, reward);
    }

    /// @notice Credit the organiser with all unspent funds after closure or expiry. Repeating is a zero-value no-op.
    function reclaim(uint256 eventId) external nonReentrant {
        EventData storage e = _event(eventId);
        if (msg.sender != e.organiser) revert NotOrganiser();
        if (!e.closed && block.timestamp <= e.endsAt) revert EventStillOpen();
        uint256 amount = e.pool;
        e.pool = 0;
        withdrawable[msg.sender] += amount;
        emit Reclaimed(eventId, msg.sender, amount);
    }

    /// @notice Withdraw the caller's full credit to the caller. A failed transfer restores the credit.
    function withdraw() external nonReentrant {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function eventInfo(uint256 eventId)
        external
        view
        returns (
            address organiser,
            bytes32 title,
            uint64 endsAt,
            bool closed,
            uint256 rewardPerCheckIn,
            uint256 pool,
            uint256 attendeeCount
        )
    {
        EventData storage e = _event(eventId);
        return (e.organiser, e.title, e.endsAt, e.closed, e.rewardPerCheckIn, e.pool, e.attendeeCount);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function _event(uint256 eventId) private view returns (EventData storage e) {
        e = _events[eventId];
        if (e.organiser == address(0)) revert UnknownEvent();
    }

    function _requireOpen(EventData storage e) private view {
        if (e.closed || block.timestamp > e.endsAt) revert EventNotOpen();
    }
}
