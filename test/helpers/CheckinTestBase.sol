// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EventCheckin} from "../../src/EventCheckin.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";

abstract contract CheckinTestBase is Test {
    uint256 internal constant ORGANISER_KEY = 0xA11CE;
    uint256 internal constant OTHER_KEY = 0xB0B;
    uint256 internal constant REWARD = 10 ether;
    address internal organiser;
    address internal attendee = address(0xCAFE);
    address internal relayer = address(0xBEEF);
    address internal funder = address(0xF00D);
    LaunchToken internal token;
    EventCheckin internal app;
    uint256 internal eventId;
    uint64 internal endsAt;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        organiser = vm.addr(ORGANISER_KEY);
        token = new LaunchToken();
        app = new EventCheckin(address(token));
        endsAt = uint64(block.timestamp + 7 days);
        eventId = _create(organiser, endsAt, REWARD);
        token.transfer(funder, 1_000 ether);
        vm.prank(funder);
        token.approve(address(app), type(uint256).max);
    }

    function _create(address who, uint64 end, uint256 reward) internal returns (uint256) {
        vm.prank(who);
        return app.createEvent(bytes32("Community meetup"), end, reward);
    }

    // Independent encoding of the public signing protocol: never use the implementation's typehash/domain to sign.
    function _domain(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("EventCheckin"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
    }

    function _digest(uint256 id, address who, uint256 deadline, bytes32 domain) internal pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(keccak256("CheckIn(uint256 eventId,address attendee,uint256 deadline)"), id, who, deadline)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _pass(uint256 id, address who, uint256 deadline) internal view returns (bytes memory) {
        return _signDigest(ORGANISER_KEY, _digest(id, who, deadline, _domain(block.chainid, address(app))));
    }

    function _fund(uint256 id, uint256 amount) internal {
        vm.prank(funder);
        app.fundEvent(id, amount);
    }

    function _checkIn(uint256 id, address who) internal {
        bytes memory sig = _pass(id, who, endsAt);
        vm.prank(relayer);
        app.checkIn(id, who, endsAt, sig);
    }

    function _pool(uint256 id) internal view returns (uint256 pool) {
        (,,,,, pool,) = app.eventInfo(id);
    }

    function _attendeeCount(uint256 id) internal view returns (uint256 count) {
        (,,,,,, count) = app.eventInfo(id);
    }

    function _close(uint256 id) internal {
        vm.prank(organiser);
        app.closeEvent(id);
    }
}
