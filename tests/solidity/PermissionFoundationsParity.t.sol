// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {BaseAllowlistChecker} from "./periphery/src/hooks/permissionedPools/BaseAllowListChecker.sol";
import {IAllowlistChecker} from "./periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag, PermissionFlags} from "./periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
}
contract PermissionReference is BaseAllowlistChecker {
    function checkAllowlist(address account, address tokenAddress) public pure override returns (PermissionFlag) {
        return PermissionFlag.wrap(bytes2(uint16(uint160(account) ^ uint160(tokenAddress))));
    }
    function flags(PermissionFlag a, PermissionFlag b) external pure returns (PermissionFlag, PermissionFlag, bool) {
        return (a | b, a & b, a == b);
    }
    function constants() external pure returns (PermissionFlag, PermissionFlag, PermissionFlag, PermissionFlag) {
        return (PermissionFlags.NONE, PermissionFlags.SWAP_ALLOWED, PermissionFlags.LIQUIDITY_ALLOWED, PermissionFlags.ALL_ALLOWED);
    }
}
contract PermissionFoundationsParityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    address referenceContract;
    function setUp() public {
        bytes memory code = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed;
        assembly ("memory-safe") { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0)); fe = deployed;
        referenceContract = address(new PermissionReference());
    }
    function compare(bytes memory data) internal view returns (bool ok, bytes memory out) {
        (bool a, bytes memory x) = fe.staticcall(data);
        (ok, out) = referenceContract.staticcall(data);
        require(a == ok, "call status");
        require(keccak256(x) == keccak256(out), "return/revert bytes");
    }
    function testFuzz_flags(bytes2 a, bytes2 b) public view {
        (bool ok,) = compare(abi.encodeWithSignature("flags(bytes2,bytes2)", a, b)); require(ok);
    }
    function testFuzz_interfaces(bytes4 id) public view {
        (bool ok,) = compare(abi.encodeWithSignature("supportsInterface(bytes4)", id)); require(ok);
    }
    function testFuzz_checker(address account, address token) public view {
        (bool ok,) = compare(abi.encodeWithSignature("checkAllowlist(address,address)", account, token)); require(ok);
    }
    function test_constantsAndInterfaceBoundaries() public view {
        (bool ok,) = compare(abi.encodeWithSignature("constants()")); require(ok);
        bytes4[4] memory ids = [bytes4(0x01ffc9a7), type(IAllowlistChecker).interfaceId, bytes4(0xffffffff), bytes4(0)];
        for (uint256 i; i < ids.length; ++i) {
            bytes memory out; (ok,out) = compare(abi.encodeWithSignature("supportsInterface(bytes4)", ids[i]));
            require(ok && abi.decode(out,(bool)) == (i < 2));
        }
    }
    function test_malformed() public view {
        compare(hex""); compare(hex"12345678");
        bytes memory valid = abi.encodeWithSignature("flags(bytes2,bytes2)", bytes2(0x0001), bytes2(0xffff));
        for (uint256 n=4; n<valid.length; ++n) {
            bytes memory short = new bytes(n);
            for (uint256 i; i<n; ++i) short[i]=valid[i];
            (bool ok,) = compare(short); require(!ok);
        }
        // Fixed bytes are left-aligned; Solidity rejects nonzero right padding.
        valid[35] = bytes1(uint8(1));
        (bool success,) = compare(valid); require(!success);
        compare(abi.encodePacked(bytes4(keccak256("supportsInterface(bytes4)")), bytes32(uint256(1))));
        compare(abi.encodePacked(bytes4(keccak256("checkAllowlist(address,address)")), bytes32(type(uint256).max),bytes32(0)));
    }
}
