// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {UniswapV4DeployerCompetition} from "./periphery/src/UniswapV4DeployerCompetition.sol";
import {VanityAddressLib} from "./periphery/src/libraries/VanityAddressLib.sol";

interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
    function etch(address, bytes calldata) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function deal(address, uint256) external;
    function warp(uint256) external;
    function prank(address) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}
contract DeployerCompetitionParityTest {
    using VanityAddressLib for address;
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant TARGET = address(0xBEE123);
    address constant OWNER = address(0xA11CE);
    bytes creation;
    bytes feRuntime;
    bytes solRuntime;
    bytes32 codeHash;
    // Constructor writes 42 to storage slot zero and returns one STOP byte.
    bytes internal init = hex"602a5f5560015ff3";
    function attempt(bytes memory code) internal returns (address a, bytes memory result) {
        assembly ("memory-safe") {
            a := create(0, add(code, 32), mload(code))
            let n := returndatasize()
            result := mload(0x40)
            mstore(result, n)
            returndatacopy(add(result, 32), 0, n)
            mstore(0x40, add(add(result, 32), and(add(n, 31), not(31))))
        }
    }
    function configure(bytes32 hash, uint256 deadline, address owner, uint256 length) internal returns (bool) {
        bytes memory args = abi.encode(hash, deadline, owner, length);
        (address a, bytes memory x) = attempt(bytes.concat(creation, args));
        (address b, bytes memory y) = attempt(bytes.concat(type(UniswapV4DeployerCompetition).creationCode, args));
        require((a == address(0)) == (b == address(0)), "constructor status");
        require(keccak256(x) == keccak256(y), "constructor revert");
        if (a == address(0)) return false;
        feRuntime = a.code; solRuntime = b.code; codeHash = hash;
        vm.etch(TARGET, solRuntime);
        vm.store(TARGET, bytes32(0), bytes32(0));
        vm.store(TARGET, bytes32(uint256(1)), bytes32(0));
        return true;
    }
    function setUp() public {
        creation = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        require(configure(keccak256(init), 1000, OWNER, 100));
        vm.deal(address(this), 100);
    }
    function predicted(bytes32 salt) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), TARGET, salt, codeHash)))));
    }
    function invoke(bytes memory data, address actor, uint256 value) internal returns (bool ok, bytes memory out, bytes32 digest) {
        vm.recordLogs(); vm.prank(actor);
        // Failed CREATE2 can consume all forwarded gas; reserve gas for the oracle branch.
        (ok, out) = TARGET.call{value: value, gas: 5_000_000}(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 salt = vm.load(TARGET, bytes32(0));
        address child = predicted(salt);
        digest = keccak256(abi.encode(vm.load(TARGET, bytes32(0)), vm.load(TARGET, bytes32(uint256(1))),
            logs, child.code, vm.load(child, bytes32(0)), child.balance, TARGET.balance));
    }
    function compare(bytes memory data, address actor, uint256 value) internal returns (bool b, bytes memory y) {
        uint256 snapshot = vm.snapshotState();
        vm.etch(TARGET, feRuntime);
        (bool a, bytes memory x, bytes32 left) = invoke(data, actor, value);
        require(vm.revertToState(snapshot));
        vm.etch(TARGET, solRuntime);
        bytes32 right; (b, y, right) = invoke(data, actor, value);
        require(a == b, "call status");
        require(keccak256(x) == keccak256(y), "return/revert bytes");
        require(left == right, "storage/events/child/rollback");
    }
    function checkGetters() internal {
        string[7] memory names = ["bestAddressSalt()", "bestAddressSubmitter()", "competitionDeadline()",
            "initCodeHash()", "deployer()", "exclusiveDeployDeadline()", "bestAddress()"];
        for (uint256 i; i < names.length; ++i) {
            (bool ok,) = compare(abi.encodeWithSignature(names[i]), OWNER, 0); require(ok);
        }
    }
    function testFuzz_constructor(bytes32 hash, uint256 deadline, address owner, uint256 length) public {
        if (configure(hash, deadline, owner, length)) checkGetters();
    }
    function testFuzz_updates(bytes32 raw, address actor, uint16 time) public {
        vm.warp(uint256(time) % 1201);
        compare(abi.encodeWithSignature("updateBestAddress(bytes32)", raw), actor, 0);
        bytes32 open = bytes32(uint256(raw) & type(uint96).max);
        compare(abi.encodeWithSignature("updateBestAddress(bytes32)", open), actor, 0);
        bytes32 owned = bytes32((uint256(uint160(actor)) << 96) | uint96(uint256(raw)));
        compare(abi.encodeWithSignature("updateBestAddress(bytes32)", owned), actor, 0);
        checkGetters();
    }
    function testFuzz_sequences(uint96 seed, uint8 count) public {
        vm.warp(1000);
        vm.store(TARGET, bytes32(uint256(1)), bytes32(type(uint256).max << 160));
        for (uint256 i; i < uint256(count) % 24 + 1; ++i) {
            bytes32 salt = bytes32((uint256(seed) + i) & type(uint96).max);
            compare(abi.encodeWithSignature("updateBestAddress(bytes32)", salt), OWNER, 0);
        }
        checkGetters();
    }
    function testFuzz_deploy(uint64 time, address actor, bool correct) public {
        vm.warp(uint256(time) % 1201);
        compare(abi.encodeWithSignature("deploy(bytes)", correct ? init : bytes(hex"00")), actor, 0);
    }
    function winningSalt() internal view returns (bytes32) {
        address best = predicted(vm.load(TARGET, bytes32(0)));
        for (uint256 i = 1; i < 100000; ++i) if (predicted(bytes32(i)).betterThan(best)) return bytes32(i);
        revert("test salt search exhausted");
    }
    function test_deadlinesAuthorizationAndDeployment() public {
        vm.warp(1000);
        bytes32 salt = winningSalt();
        (bool ok,) = compare(abi.encodeWithSignature("updateBestAddress(bytes32)", salt), OWNER, 0); require(ok);
        (ok,) = compare(abi.encodeWithSignature("updateBestAddress(bytes32)", salt), OWNER, 0); require(!ok, "equal score");
        (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), OWNER, 0); require(!ok);
        vm.warp(1001);
        (ok,) = compare(abi.encodeWithSignature("updateBestAddress(bytes32)", bytes32(type(uint256).max)), address(123), 0); require(!ok);
        (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), address(123), 0); require(!ok);
        vm.deal(TARGET, 11); vm.deal(predicted(salt), 7);
        (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), OWNER, 0); require(ok);
        require(predicted(salt).code.length == 1 && uint256(vm.load(predicted(salt), bytes32(0))) == 42);
        (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), OWNER, 0); require(!ok, "CREATE2 collision");
        require(configure(keccak256(init), 1000, OWNER, 100));
        vm.warp(1100); (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), address(123), 0); require(!ok);
        // A different salt avoids the deployment made earlier in this scenario.
        vm.store(TARGET, bytes32(0), bytes32(uint256(0x123456)));
        vm.warp(1101); (ok,) = compare(abi.encodeWithSignature("deploy(bytes)", init), address(123), 0); require(ok);
    }
    function test_create2FailuresAndEmptyRuntime() public {
        bytes[4] memory variants = [bytes(""), bytes(hex"63deadbeef5f526004601cfd"), bytes(hex"fe"), bytes(hex"00")];
        for (uint256 i; i < variants.length; ++i) {
            require(configure(keccak256(variants[i]), 1000, OWNER, 100)); vm.warp(1101);
            (bool ok, bytes memory out) = compare(abi.encodeWithSignature("deploy(bytes)", variants[i]), address(123), 0);
            require(ok == (i == 3), "creation outcome");
            if (i == 0) require(bytes4(out) == bytes4(keccak256("Create2EmptyBytecode()")));
            if (i == 1 || i == 2) require(bytes4(out) == bytes4(keccak256("Create2FailedDeployment()")));
        }
    }
    function test_nonpayableAndMalformedCalls() public {
        compare(hex"", OWNER, 0); compare(hex"12345678", OWNER, 0);
        compare(abi.encodeWithSignature("bestAddress()"), OWNER, 1);
        compare(abi.encodeWithSignature("deploy(bytes)", init), OWNER, 1);
        bytes memory full = abi.encodeWithSignature("updateBestAddress(bytes32)", bytes32(0));
        for (uint256 n = 4; n < full.length; ++n) {
            bytes memory short = new bytes(n);
            for (uint256 i; i < n; ++i) short[i] = full[i];
            compare(short, OWNER, 0);
        }
        compare(abi.encodePacked(bytes4(keccak256("deploy(bytes)")), bytes32(type(uint256).max)), OWNER, 0);
    }
}
