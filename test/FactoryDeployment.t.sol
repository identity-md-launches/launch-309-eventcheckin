// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {EventCheckin} from "../src/EventCheckin.sol";

contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "deployment failed");
    }
}

contract FactoryDeploymentTest is Test {
    function test_factoryConstructorsPreserveFullSupplyAndRequireNoInitialization() public {
        vm.chainId(11155111);
        FactoryProbe factory = new FactoryProbe();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        EventCheckin app = EventCheckin(
            factory.deploy(
                abi.encodePacked(type(EventCheckin).creationCode, abi.encode(address(token))), bytes32(uint256(2))
            )
        );
        assertEq(address(app.token()), address(token));
        assertEq(token.balanceOf(address(app)), 0);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(app.eventCount(), 0);
        vm.prank(address(0xA11CE));
        uint256 id = app.createEvent(bytes32("Factory launch"), uint64(block.timestamp + 1 days), 0);
        (address organiser,,,,,,) = app.eventInfo(id);
        assertEq(organiser, address(0xA11CE));
        _checkRuntime(address(token).code);
        _checkRuntime(address(app).code);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
