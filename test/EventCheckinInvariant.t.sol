// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {EventCheckin} from "../src/EventCheckin.sol";

/// @dev Separate accounting model, updated from intended operations rather than from the application's balances.
contract CheckinHandler is Test {
    struct ModelEvent {
        uint256 organiserIndex;
        uint64 end;
        bool closed;
        uint256 reward;
        uint256 pool;
        uint256 count;
    }

    LaunchToken public immutable token;
    EventCheckin public immutable app;
    address[6] public actors;
    uint256[2] private keys = [uint256(0xA11CE), uint256(0xB0B)];
    ModelEvent[] public model;
    mapping(address => uint256) public credit;
    mapping(address => uint256) public totalAttendance;
    mapping(uint256 => mapping(address => bool)) public recorded;
    uint256 public funded;
    uint256 public paid;

    constructor(LaunchToken token_, EventCheckin app_) {
        token = token_;
        app = app_;
        actors = [vm.addr(keys[0]), vm.addr(keys[1]), address(0x101), address(0x102), address(0x103), address(0x104)];
        token.approve(address(app), type(uint256).max);
        _create(0, 10 ether, 7 days);
        _create(1, 3 ether, 2 days);
        _create(0, 0, 14 days);
    }

    function create(uint256 ownerSeed, uint256 rewardSeed, uint256 lifetimeSeed) external {
        if (model.length >= 16) return;
        _create(ownerSeed % 2, bound(rewardSeed, 0, 100 ether), bound(lifetimeSeed, 1, 365 days));
    }

    function fund(uint256 eventSeed, uint256 amountSeed) external {
        uint256 index = eventSeed % model.length;
        ModelEvent storage e = model[index];
        if (e.closed || block.timestamp > e.end) return;
        uint256 available = token.balanceOf(address(this));
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available < 1_000 ether ? available : 1_000 ether);
        app.fundEvent(index + 1, amount);
        e.pool += amount;
        funded += amount;
    }

    function checkIn(uint256 eventSeed, uint256 actorSeed) external {
        uint256 index = eventSeed % model.length;
        ModelEvent storage e = model[index];
        address who = actors[actorSeed % actors.length];
        uint256 id = index + 1;
        if (e.closed || block.timestamp > e.end || recorded[id][who]) return;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("EventCheckin"),
                keccak256("1"),
                block.chainid,
                address(app)
            )
        );
        bytes32 pass = keccak256(
            abi.encode(keccak256("CheckIn(uint256 eventId,address attendee,uint256 deadline)"), id, who, uint256(e.end))
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[e.organiserIndex], keccak256(abi.encodePacked(hex"1901", domain, pass)));
        app.checkIn(id, who, e.end, abi.encodePacked(r, s, v));
        recorded[id][who] = true;
        ++totalAttendance[who];
        ++e.count;
        if (e.pool >= e.reward) {
            e.pool -= e.reward;
            credit[who] += e.reward;
        }
    }

    function close(uint256 eventSeed) external {
        uint256 index = eventSeed % model.length;
        ModelEvent storage e = model[index];
        if (e.closed) return;
        vm.prank(actors[e.organiserIndex]);
        app.closeEvent(index + 1);
        e.closed = true;
    }

    function reclaim(uint256 eventSeed) external {
        uint256 index = eventSeed % model.length;
        ModelEvent storage e = model[index];
        if (!e.closed && block.timestamp <= e.end) return;
        address who = actors[e.organiserIndex];
        vm.prank(who);
        app.reclaim(index + 1);
        credit[who] += e.pool;
        e.pool = 0;
    }

    function withdraw(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        uint256 amount = credit[who];
        if (amount == 0) return;
        vm.prank(who);
        app.withdraw();
        credit[who] = 0;
        paid += amount;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 1 days));
    }

    function modelCount() external view returns (uint256) {
        return model.length;
    }

    function modelAt(uint256 index) external view returns (ModelEvent memory) {
        return model[index];
    }

    function _create(uint256 ownerIndex, uint256 reward, uint256 lifetime) private {
        uint64 end = uint64(block.timestamp + lifetime);
        vm.prank(actors[ownerIndex]);
        uint256 id = app.createEvent(bytes32("Fuzz event"), end, reward);
        model.push(ModelEvent(ownerIndex, end, false, reward, 0, 0));
        assertEq(id, model.length);
    }
}

contract EventCheckinInvariantTest is StdInvariant, Test {
    LaunchToken internal token;
    EventCheckin internal app;
    CheckinHandler internal handler;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        token = new LaunchToken();
        app = new EventCheckin(address(token));
        handler = new CheckinHandler(token, app);
        token.transfer(address(handler), 1_000_000 ether);
        // Start with multiple funded pools, a rewarded attendee, an unrewarded attendee, and organiser credit.
        handler.fund(0, 100 ether);
        handler.fund(1, 1 ether);
        handler.checkIn(0, 2);
        handler.checkIn(1, 3);
        handler.close(1);
        handler.reclaim(1);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.checkIn.selector;
        selectors[3] = handler.close.selector;
        selectors[4] = handler.reclaim.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_poolsCreditsAndAttendanceMatchIndependentModel() public view {
        uint256 liabilities;
        uint256 count = handler.modelCount();
        assertEq(app.eventCount(), count);
        for (uint256 i; i < count; ++i) {
            liabilities += _assertEvent(i);
            for (uint256 j; j < 6; ++j) {
                address actor = handler.actors(j);
                assertEq(app.attended(i + 1, actor), handler.recorded(i + 1, actor));
            }
        }
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            assertEq(app.withdrawable(actor), handler.credit(actor));
            assertEq(app.attendanceCount(actor), handler.totalAttendance(actor));
            liabilities += app.withdrawable(actor);
        }
        assertEq(token.balanceOf(address(app)), liabilities);
        assertEq(handler.funded(), liabilities + handler.paid());
        assertEq(app.withdrawable(address(handler)), 0);
        assertEq(app.attendanceCount(address(handler)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function _assertEvent(uint256 index) private view returns (uint256) {
        CheckinHandler.ModelEvent memory expected = handler.modelAt(index);
        (address owner,, uint64 end, bool closed, uint256 reward, uint256 pool, uint256 attendeeCount) =
            app.eventInfo(index + 1);
        assertEq(owner, handler.actors(expected.organiserIndex));
        assertEq(end, expected.end);
        assertEq(closed, expected.closed);
        assertEq(reward, expected.reward);
        assertEq(pool, expected.pool);
        assertEq(attendeeCount, expected.count);
        return pool;
    }
}
