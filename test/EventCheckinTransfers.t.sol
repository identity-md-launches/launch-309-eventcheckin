// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CheckinTestBase, EventCheckin} from "./helpers/CheckinTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Fault injection only; the production deployment uses the fixed LaunchToken.
contract FaultToken is ERC20 {
    bool public fail;
    bool public fee;
    bool public reenter;
    bool public attempted;
    bool public succeeded;
    bytes4 public reentryError;
    EventCheckin public app;

    constructor() ERC20("Fault", "FAULT") {
        _mint(msg.sender, 1e27);
    }

    function configure(EventCheckin app_, bool fail_, bool fee_, bool reenter_) external {
        app = app_;
        fail = fail_;
        fee = fee_;
        reenter = reenter_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        if (reenter) _attempt();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        if (reenter) _attempt();
        bool ok = super.transferFrom(from, to, amount);
        if (fee) _burn(to, 1);
        return ok;
    }

    function _attempt() internal {
        attempted = true;
        bytes memory result;
        (succeeded, result) = address(app).call(abi.encodeCall(app.withdraw, ()));
        if (result.length >= 4) reentryError = bytes4(result);
    }
}

contract EventCheckinTransfersTest is CheckinTestBase {
    FaultToken internal fault;

    function setUp() public override {
        super.setUp();
        fault = new FaultToken();
        app = new EventCheckin(address(fault));
        eventId = _create(organiser, endsAt, REWARD);
        fault.approve(address(app), type(uint256).max);
        app.fundEvent(eventId, 3 * REWARD);
    }

    function test_failedWithdrawalRestoresCreditAndOtherUsersCanWithdraw() public {
        _checkIn(eventId, attendee);
        _checkIn(eventId, relayer);
        fault.configure(app, true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(fault)));
        vm.prank(attendee);
        app.withdraw();
        assertEq(app.withdrawable(attendee), REWARD);
        assertEq(fault.balanceOf(address(app)), 3 * REWARD);
        fault.configure(app, false, false, false);
        vm.prank(relayer);
        app.withdraw();
        vm.prank(attendee);
        app.withdraw();
        assertEq(fault.balanceOf(relayer), REWARD);
        assertEq(fault.balanceOf(attendee), REWARD);
        assertEq(fault.balanceOf(address(app)), REWARD);
    }

    function test_failedFundingLeavesNoPoolCredit() public {
        fault.configure(app, true, false, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(fault)));
        app.fundEvent(eventId, REWARD);
        assertEq(_pool(eventId), 3 * REWARD);
        assertEq(fault.balanceOf(address(app)), 3 * REWARD);
    }

    function test_feeOnTransferFundingRejectedAtomically() public {
        fault.configure(app, false, true, false);
        uint256 beforeBalance = fault.balanceOf(address(this));
        vm.expectRevert(EventCheckin.UnexpectedTokenAmount.selector);
        app.fundEvent(eventId, REWARD);
        assertEq(_pool(eventId), 3 * REWARD);
        assertEq(fault.balanceOf(address(app)), 3 * REWARD);
        assertEq(fault.balanceOf(address(this)), beforeBalance);
    }

    function test_reentrantWithdrawalCannotSpendCreditTwice() public {
        _checkIn(eventId, address(fault));
        fault.configure(app, false, false, true);
        vm.prank(address(fault));
        app.withdraw();
        assertTrue(fault.attempted());
        assertFalse(fault.succeeded());
        assertEq(fault.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(app.withdrawable(address(fault)), 0);
        assertEq(fault.balanceOf(address(fault)), REWARD);
        assertEq(fault.balanceOf(address(app)), 2 * REWARD);
    }

    function test_reentryWhileFundingCannotSpendExistingCredits() public {
        _checkIn(eventId, address(fault));
        fault.configure(app, false, false, true);
        app.fundEvent(eventId, REWARD);
        assertTrue(fault.attempted());
        assertFalse(fault.succeeded());
        assertEq(fault.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(app.withdrawable(address(fault)), REWARD);
        assertEq(_pool(eventId), 3 * REWARD);
        assertEq(fault.balanceOf(address(app)), 4 * REWARD);
    }
}
