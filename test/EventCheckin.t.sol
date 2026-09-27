// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheckinTestBase, EventCheckin} from "./helpers/CheckinTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract EventCheckinTest is CheckinTestBase {
    function test_constructorHasNoFundingOrGlobalOrganiser() public view {
        assertEq(address(app.token()), address(token));
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.balanceOf(address(this)), 1e27 - 1_000 ether);
        assertEq(app.withdrawable(address(this)), 0);
    }

    function test_constructorRejectsZeroOrNonContractToken() public {
        vm.expectRevert(EventCheckin.InvalidToken.selector);
        new EventCheckin(address(0));
        vm.expectRevert(EventCheckin.InvalidToken.selector);
        new EventCheckin(attendee);
    }

    function test_createEventViewsAndSequentialIds() public {
        assertEq(eventId, 1);
        assertEq(app.eventCount(), 1);
        (address who, bytes32 title, uint64 end, bool closed, uint256 reward, uint256 pool, uint256 count) =
            app.eventInfo(eventId);
        assertEq(who, organiser);
        assertEq(title, bytes32("Community meetup"));
        assertEq(end, endsAt);
        assertFalse(closed);
        assertEq(reward, REWARD);
        assertEq(pool, 0);
        assertEq(count, 0);

        vm.expectEmit(true, true, false, true, address(app));
        emit EventCheckin.EventCreated(2, attendee, bytes32("Community meetup"), endsAt, 0);
        assertEq(_create(attendee, endsAt, 0), 2);
        assertEq(app.eventCount(), 2);
    }

    function test_createEndTimeBoundaries() public {
        vm.expectRevert(EventCheckin.InvalidEndTime.selector);
        _create(organiser, uint64(block.timestamp), REWARD);
        vm.expectRevert(EventCheckin.InvalidEndTime.selector);
        _create(organiser, uint64(block.timestamp - 1), REWARD);
        vm.expectRevert(EventCheckin.InvalidEndTime.selector);
        _create(organiser, uint64(block.timestamp + 365 days + 1), REWARD);
        _create(organiser, uint64(block.timestamp + 1), 0);
        _create(organiser, uint64(block.timestamp + 365 days), type(uint256).max);
    }

    function test_unknownEventsRevertWithoutChangingState() public {
        uint256[2] memory ids = [uint256(0), uint256(2)];
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            vm.expectRevert(EventCheckin.UnknownEvent.selector);
            app.eventInfo(id);
            vm.expectRevert(EventCheckin.UnknownEvent.selector);
            app.fundEvent(id, 1);
            vm.expectRevert(EventCheckin.UnknownEvent.selector);
            app.closeEvent(id);
            vm.expectRevert(EventCheckin.UnknownEvent.selector);
            app.checkIn(id, attendee, endsAt, hex"");
            vm.expectRevert(EventCheckin.UnknownEvent.selector);
            app.reclaim(id);
            assertFalse(app.attended(id, attendee));
        }
    }

    function test_anyoneCanFundWithApproval() public {
        vm.expectEmit(true, true, false, true, address(app));
        emit EventCheckin.EventFunded(eventId, funder, 25 ether);
        _fund(eventId, 25 ether);
        assertEq(_pool(eventId), 25 ether);
        assertEq(token.balanceOf(address(app)), 25 ether);
        assertEq(token.balanceOf(funder), 975 ether);
    }

    function test_fundZeroOrMissingApprovalReverts() public {
        vm.expectRevert(EventCheckin.InvalidAmount.selector);
        _fund(eventId, 0);
        vm.prank(funder);
        token.approve(address(app), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(app), 0, 1 ether)
        );
        _fund(eventId, 1 ether);
        assertEq(_pool(eventId), 0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_validEOAPassRelayerCreditsOnlyAttendeeAndEmits() public {
        _fund(eventId, 2 * REWARD);
        vm.expectEmit(true, true, true, true, address(app));
        emit EventCheckin.CheckedIn(eventId, attendee, relayer, REWARD);
        _checkIn(eventId, attendee);
        assertTrue(app.attended(eventId, attendee));
        assertEq(app.attendanceCount(attendee), 1);
        assertEq(_attendeeCount(eventId), 1);
        assertEq(app.withdrawable(attendee), REWARD);
        assertEq(_pool(eventId), REWARD);
        assertFalse(app.attended(eventId, relayer));
        assertEq(app.attendanceCount(relayer), 0);
        assertEq(app.withdrawable(relayer), 0);
        assertEq(token.balanceOf(attendee), 0);
        assertEq(token.balanceOf(address(app)), 2 * REWARD);
    }

    function test_shortPoolStillRecordsAttendanceWithoutRewardOrLaterTopUp() public {
        _fund(eventId, REWARD - 1);
        vm.expectEmit(true, true, true, true, address(app));
        emit EventCheckin.CheckedIn(eventId, attendee, relayer, 0);
        _checkIn(eventId, attendee);
        assertTrue(app.attended(eventId, attendee));
        assertEq(app.attendanceCount(attendee), 1);
        assertEq(_attendeeCount(eventId), 1);
        assertEq(app.withdrawable(attendee), 0);
        assertEq(_pool(eventId), REWARD - 1);
        _fund(eventId, 1);
        assertEq(app.withdrawable(attendee), 0);
        vm.expectRevert(EventCheckin.AlreadyAttended.selector);
        _checkIn(eventId, attendee);
    }

    function test_zeroRewardEventCanRecordWithNoFunding() public {
        uint256 free = _create(organiser, endsAt, 0);
        _checkIn(free, attendee);
        assertTrue(app.attended(free, attendee));
        assertEq(app.withdrawable(attendee), 0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function test_sameAttendeeCanAttendSeparateEvents() public {
        uint256 other = _create(organiser, endsAt, REWARD);
        _checkIn(eventId, attendee);
        _checkIn(other, attendee);
        assertEq(app.attendanceCount(attendee), 2);
        assertEq(_attendeeCount(eventId), 1);
        assertEq(_attendeeCount(other), 1);
    }

    function test_duplicateCannotWithdrawAnotherRewardEvenWithNewDeadline() public {
        _fund(eventId, 2 * REWARD);
        _checkIn(eventId, attendee);
        vm.expectRevert(EventCheckin.AlreadyAttended.selector);
        _checkIn(eventId, attendee);
        bytes memory sig = _pass(eventId, attendee, endsAt + 1);
        vm.expectRevert(EventCheckin.AlreadyAttended.selector);
        app.checkIn(eventId, attendee, endsAt + 1, sig);
        assertEq(app.withdrawable(attendee), REWARD);
        assertEq(_pool(eventId), REWARD);
        assertEq(_attendeeCount(eventId), 1);
    }

    function test_closeIsOrganiserOnlyIrreversibleAndStopsFundingAndCheckin() public {
        vm.expectRevert(EventCheckin.NotOrganiser.selector);
        vm.prank(attendee);
        app.closeEvent(eventId);
        vm.expectEmit(true, false, false, true, address(app));
        emit EventCheckin.EventClosed(eventId);
        _close(eventId);
        (,,, bool closed,,,) = app.eventInfo(eventId);
        assertTrue(closed);
        vm.expectRevert(EventCheckin.AlreadyClosed.selector);
        _close(eventId);
        vm.expectRevert(EventCheckin.EventNotOpen.selector);
        _fund(eventId, 1);
        vm.expectRevert(EventCheckin.EventNotOpen.selector);
        _checkIn(eventId, attendee);
    }

    function test_endsAtIsInclusiveThenEntryAndFundingStop() public {
        vm.warp(endsAt);
        _fund(eventId, REWARD);
        _checkIn(eventId, attendee);
        vm.expectRevert(EventCheckin.EventStillOpen.selector);
        vm.prank(organiser);
        app.reclaim(eventId);
        vm.warp(uint256(endsAt) + 1);
        vm.expectRevert(EventCheckin.EventNotOpen.selector);
        _fund(eventId, 1);
        bytes memory sig = _pass(eventId, relayer, type(uint256).max);
        vm.expectRevert(EventCheckin.EventNotOpen.selector);
        app.checkIn(eventId, relayer, type(uint256).max, sig);
    }

    function test_reclaimRequiresOrganiserAndClosedOrExpiredPaysOnlyOnce() public {
        _fund(eventId, 3 * REWARD);
        _checkIn(eventId, attendee);
        vm.expectRevert(EventCheckin.EventStillOpen.selector);
        vm.prank(organiser);
        app.reclaim(eventId);
        _close(eventId);
        vm.expectRevert(EventCheckin.NotOrganiser.selector);
        vm.prank(funder);
        app.reclaim(eventId);
        vm.expectEmit(true, true, false, true, address(app));
        emit EventCheckin.Reclaimed(eventId, organiser, 2 * REWARD);
        vm.prank(organiser);
        app.reclaim(eventId);
        vm.prank(organiser);
        app.reclaim(eventId);
        assertEq(_pool(eventId), 0);
        assertEq(app.withdrawable(organiser), 2 * REWARD);
        assertEq(app.withdrawable(attendee), REWARD);
        assertEq(token.balanceOf(address(app)), 3 * REWARD);
    }

    function test_expiredEventReclaimsWithoutExplicitClose() public {
        _fund(eventId, REWARD);
        vm.warp(uint256(endsAt) + 1);
        vm.prank(organiser);
        app.reclaim(eventId);
        assertEq(app.withdrawable(organiser), REWARD);
        assertEq(_pool(eventId), 0);
    }

    function test_withdrawOnlyCallerFullBalanceAndCannotRepeat() public {
        _fund(eventId, REWARD);
        _checkIn(eventId, attendee);
        vm.expectRevert(EventCheckin.NothingToWithdraw.selector);
        vm.prank(relayer);
        app.withdraw();
        vm.expectEmit(true, false, false, true, address(app));
        emit EventCheckin.Withdrawn(attendee, REWARD);
        vm.prank(attendee);
        app.withdraw();
        assertEq(token.balanceOf(attendee), REWARD);
        assertEq(app.withdrawable(attendee), 0);
        assertEq(token.balanceOf(address(app)), 0);
        vm.expectRevert(EventCheckin.NothingToWithdraw.selector);
        vm.prank(attendee);
        app.withdraw();
    }

    function test_separatePoolsAndReclaimCannotSpendOtherEventsOrAccruedRewards() public {
        address otherOrganiser = vm.addr(OTHER_KEY);
        uint256 other = _create(otherOrganiser, endsAt, REWARD);
        _fund(eventId, REWARD - 1);
        _fund(other, 5 * REWARD);
        _checkIn(eventId, attendee);
        assertEq(app.withdrawable(attendee), 0);
        assertEq(_pool(other), 5 * REWARD);
        _close(eventId);
        vm.prank(organiser);
        app.reclaim(eventId);
        vm.prank(organiser);
        app.withdraw();
        assertEq(token.balanceOf(address(app)), 5 * REWARD);
        assertEq(_pool(other), 5 * REWARD);
        vm.expectRevert(EventCheckin.NotOrganiser.selector);
        vm.prank(organiser);
        app.closeEvent(other);
        vm.expectRevert(EventCheckin.NotOrganiser.selector);
        vm.prank(organiser);
        app.reclaim(other);
    }

    function test_closeReclaimBeforeCheckinMakesPassUnusable() public {
        _fund(eventId, REWARD);
        bytes memory sig = _pass(eventId, attendee, endsAt);
        _close(eventId);
        vm.prank(organiser);
        app.reclaim(eventId);
        vm.expectRevert(EventCheckin.EventNotOpen.selector);
        app.checkIn(eventId, attendee, endsAt, sig);
        assertFalse(app.attended(eventId, attendee));
        assertEq(app.withdrawable(organiser), REWARD);
        assertEq(app.withdrawable(attendee), 0);
    }

    function test_unsolicitedTransferIsSurplusAndDoesNotFundEvents() public {
        token.transfer(address(app), REWARD);
        _checkIn(eventId, attendee);
        assertEq(_pool(eventId), 0);
        assertEq(app.withdrawable(attendee), 0);
        assertEq(token.balanceOf(address(app)), REWARD);
    }

    function test_noPayableFallbackReceiveOrAttendanceTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool receiveOk,) = address(app).call{value: 1}("");
        assertFalse(receiveOk);
        (bool functionOk,) =
            address(app).call{value: 1}(abi.encodeCall(app.createEvent, (bytes32("x"), endsAt, uint256(0))));
        assertFalse(functionOk);
        (bool fallbackOk,) = address(app).call(hex"12345678");
        assertFalse(fallbackOk);
        _checkIn(eventId, attendee);
        vm.prank(attendee);
        (bool transferOk,) = address(app)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", attendee, relayer, eventId));
        assertFalse(transferOk);
        assertTrue(app.attended(eventId, attendee));
        assertFalse(app.attended(eventId, relayer));
    }

    function testFuzz_rewardAndReclaimConserveFunds(uint128 poolAmount, uint128 rewardAmount) public {
        uint256 pool = bound(poolAmount, 1, 1_000 ether);
        uint256 reward = uint256(rewardAmount);
        uint256 id = _create(organiser, endsAt, reward);
        _fund(id, pool);
        _checkIn(id, attendee);
        uint256 expected = pool >= reward ? reward : 0;
        assertEq(app.withdrawable(attendee), expected);
        assertEq(_pool(id), pool - expected);
        assertEq(token.balanceOf(address(app)), _pool(id) + app.withdrawable(attendee));
        _close(id);
        vm.prank(organiser);
        app.reclaim(id);
        assertEq(token.balanceOf(address(app)), app.withdrawable(organiser) + app.withdrawable(attendee));
        if (expected != 0) {
            vm.prank(attendee);
            app.withdraw();
        }
        if (pool != expected) {
            vm.prank(organiser);
            app.withdraw();
        }
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.balanceOf(attendee) + token.balanceOf(organiser), pool);
    }
}
