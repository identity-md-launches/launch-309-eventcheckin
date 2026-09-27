// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheckinTestBase, EventCheckin} from "./helpers/CheckinTestBase.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract OrganiserWallet is IERC1271 {
    enum Mode {
        Accept,
        Reject,
        Revert,
        ShortReturn,
        ExhaustGas,
        Reenter
    }

    address internal immutable signer;
    Mode internal mode;
    EventCheckin internal target;

    constructor(address signer_) {
        signer = signer_;
    }

    function setMode(Mode mode_, EventCheckin target_) external {
        mode = mode_;
        target = target_;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (mode == Mode.Revert) revert("wallet unavailable");
        if (mode == Mode.ShortReturn) {
            assembly {
                mstore(0, 0x1626ba7e)
                return(28, 4)
            }
        }
        if (mode == Mode.ExhaustGas) {
            assembly {
                for {} 1 {} {}
            }
        }
        if (mode == Mode.Reenter) {
            (bool ok,) = address(target)
                .staticcall(abi.encodeCall(target.createEvent, (bytes32(0), uint64(block.timestamp + 1 days), 0)));
            // Reentrancy must not create an event during signature validation.
            if (ok) return bytes4(0);
        }
        if (mode == Mode.Reject) return bytes4(0);
        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(hash, signature);
        return
            error == ECDSA.RecoverError.NoError && recovered == signer ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract EventCheckinSignaturesTest is CheckinTestBase {
    function test_publicDomainAndTypehashMatchTypedDataProtocol() public view {
        assertEq(app.CHECKIN_TYPEHASH(), keccak256("CheckIn(uint256 eventId,address attendee,uint256 deadline)"));
        assertEq(app.domainSeparator(), _domain(11155111, address(app)));
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chain,
            address verifier,
            bytes32 salt,
            uint256[] memory extensions
        ) = app.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "EventCheckin");
        assertEq(version, "1");
        assertEq(chain, 11155111);
        assertEq(verifier, address(app));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    function test_wrongSignerCannotImpersonateOrganiser() public {
        bytes memory sig =
            _signDigest(OTHER_KEY, _digest(eventId, attendee, endsAt, _domain(block.chainid, address(app))));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        vm.prank(organiser);
        app.checkIn(eventId, attendee, endsAt, sig);
        assertFalse(app.attended(eventId, attendee));
        assertEq(_attendeeCount(eventId), 0);
    }

    function test_signatureCannotBeReplayedAcrossEventsAttendeesOrDeadlines() public {
        bytes memory sig = _pass(eventId, attendee, endsAt);
        uint256 other = _create(organiser, endsAt, REWARD);
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(other, attendee, endsAt, sig);
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, relayer, endsAt, sig);
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, uint256(endsAt) + 1, sig);
        assertEq(app.attendanceCount(attendee), 0);
        assertEq(app.attendanceCount(relayer), 0);
    }

    function test_wrongChainAndPostForkReplayFail() public {
        bytes memory wrong = _signDigest(ORGANISER_KEY, _digest(eventId, attendee, endsAt, _domain(1, address(app))));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, wrong);
        bytes memory original =
            _signDigest(ORGANISER_KEY, _digest(eventId, attendee, endsAt, _domain(11155111, address(app))));
        vm.chainId(11155112);
        assertEq(app.domainSeparator(), _domain(11155112, address(app)));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, original);
        bytes memory forkPass =
            _signDigest(ORGANISER_KEY, _digest(eventId, attendee, endsAt, _domain(11155112, address(app))));
        app.checkIn(eventId, attendee, endsAt, forkPass);
    }

    function test_passCannotBeReplayedAgainstAnotherDeployment() public {
        bytes memory sig = _pass(eventId, attendee, endsAt);
        EventCheckin second = new EventCheckin(address(token));
        vm.prank(organiser);
        assertEq(second.createEvent(bytes32("Community meetup"), endsAt, REWARD), eventId);
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        second.checkIn(eventId, attendee, endsAt, sig);
    }

    function test_wrongDomainNameVersionAndStructNameFail() public {
        bytes32 domainType =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 wrongName =
            keccak256(abi.encode(domainType, keccak256("Checkin"), keccak256("1"), block.chainid, address(app)));
        bytes32 wrongVersion =
            keccak256(abi.encode(domainType, keccak256("EventCheckin"), keccak256("2"), block.chainid, address(app)));
        bytes memory sig = _signDigest(ORGANISER_KEY, _digest(eventId, attendee, endsAt, wrongName));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, sig);
        sig = _signDigest(ORGANISER_KEY, _digest(eventId, attendee, endsAt, wrongVersion));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, sig);
        bytes32 wrongStruct = keccak256(
            abi.encode(
                keccak256("Checkin(uint256 eventId,address attendee,uint256 deadline)"), eventId, attendee, endsAt
            )
        );
        sig = _signDigest(
            ORGANISER_KEY, keccak256(abi.encodePacked(hex"1901", _domain(block.chainid, address(app)), wrongStruct))
        );
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, sig);
    }

    function test_expiredDeadlineFailsAndExactDeadlineSucceeds() public {
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _pass(eventId, attendee, deadline);
        bytes memory other = _pass(eventId, relayer, deadline);
        vm.warp(deadline);
        app.checkIn(eventId, attendee, deadline, sig);
        vm.warp(deadline + 1);
        vm.expectRevert(EventCheckin.PassExpired.selector);
        app.checkIn(eventId, relayer, deadline, other);
        assertFalse(app.attended(eventId, relayer));
    }

    function test_zeroAttendeeRejectedEvenWhenSigned() public {
        bytes memory sig = _pass(eventId, address(0), endsAt);
        vm.expectRevert(EventCheckin.InvalidAttendee.selector);
        app.checkIn(eventId, address(0), endsAt, sig);
    }

    function test_highSMalleabilityInvalidVAndMalformedSignaturesRejected() public {
        bytes32 digest = _digest(eventId, attendee, endsAt, _domain(block.chainid, address(app)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ORGANISER_KEY, digest);
        uint256 curveOrder = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory highS = abi.encodePacked(r, bytes32(curveOrder - uint256(s)), uint8(v == 27 ? 28 : 27));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, highS);
        bytes memory invalidV = abi.encodePacked(r, s, uint8(0));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, invalidV);
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, hex"");
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, new bytes(64));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, new bytes(65));
        vm.expectRevert(EventCheckin.InvalidSignature.selector);
        app.checkIn(eventId, attendee, endsAt, abi.encodePacked(r, s, v, bytes1(0)));
        _checkIn(eventId, attendee);
    }

    function test_ERC1271OrganiserAcceptsOwnSignatureAndCanReclaim() public {
        OrganiserWallet wallet = new OrganiserWallet(organiser);
        uint256 id = _create(address(wallet), endsAt, REWARD);
        _fund(id, 2 * REWARD);
        _checkIn(id, attendee);
        assertTrue(app.attended(id, attendee));
        assertEq(app.withdrawable(attendee), REWARD);
        vm.prank(organiser);
        vm.expectRevert(EventCheckin.NotOrganiser.selector);
        app.closeEvent(id);
        vm.prank(address(wallet));
        app.closeEvent(id);
        vm.prank(address(wallet));
        app.reclaim(id);
        assertEq(app.withdrawable(address(wallet)), REWARD);
        vm.prank(address(wallet));
        app.withdraw();
        assertEq(token.balanceOf(address(wallet)), REWARD);
    }

    function test_ERC1271RejectRevertAndShortResponseDoNotConsumePassOrPool() public {
        OrganiserWallet wallet = new OrganiserWallet(organiser);
        uint256 id = _create(address(wallet), endsAt, REWARD);
        _fund(id, REWARD);
        for (uint256 m = 1; m <= 3; ++m) {
            wallet.setMode(OrganiserWallet.Mode(m), app);
            vm.expectRevert(EventCheckin.InvalidSignature.selector);
            _checkIn(id, attendee);
            assertFalse(app.attended(id, attendee));
            assertEq(_pool(id), REWARD);
            assertEq(app.withdrawable(attendee), 0);
        }
        wallet.setMode(OrganiserWallet.Mode.Accept, app);
        _checkIn(id, attendee);
        assertEq(app.withdrawable(attendee), REWARD);
    }

    function test_ERC1271GasGriefOnlyFailsThatSubmission() public {
        OrganiserWallet wallet = new OrganiserWallet(organiser);
        uint256 id = _create(address(wallet), endsAt, REWARD);
        wallet.setMode(OrganiserWallet.Mode.ExhaustGas, app);
        bytes memory sig = _pass(id, attendee, endsAt);
        (bool ok,) = address(app).call{gas: 200_000}(abi.encodeCall(app.checkIn, (id, attendee, endsAt, sig)));
        assertFalse(ok);
        assertFalse(app.attended(id, attendee));
        assertEq(_attendeeCount(id), 0);
        _fund(eventId, REWARD);
        _checkIn(eventId, attendee);
        vm.prank(attendee);
        app.withdraw();
        assertEq(token.balanceOf(attendee), REWARD);
    }

    function test_ERC1271CannotMutateStateDuringValidation() public {
        OrganiserWallet wallet = new OrganiserWallet(organiser);
        uint256 id = _create(address(wallet), endsAt, REWARD);
        wallet.setMode(OrganiserWallet.Mode.Reenter, app);
        _checkIn(id, attendee);
        assertEq(app.eventCount(), 2);
        assertTrue(app.attended(id, attendee));
    }
}
