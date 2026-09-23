// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PositionDescriptor} from "./periphery/src/PositionDescriptor.sol";
import {IPositionManager} from "./periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionInfo, PositionInfoLibrary} from "./periphery/src/libraries/PositionInfoLibrary.sol";

interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
    function chainId(uint256) external;
    function deal(address, uint256) external;
}
contract DescriptorPositionData {
    bytes data;
    bool fails;
    function configure(bytes memory value, bool failure) external { data = value; fails = failure; }
    fallback(bytes calldata input) external returns (bytes memory) {
        require(bytes4(input) == IPositionManager.getPoolAndPositionInfo.selector, "position selector");
        bytes memory result = data;
        if (fails) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
}
contract DescriptorPoolData {
    bytes data;
    bool fails;
    bytes32 expectedSlot;
    function configure(bytes32 slot, bytes memory value, bool failure) external {
        expectedSlot = slot; data = value; fails = failure;
    }
    function extsload(bytes32 slot) external view returns (bytes32) {
        require(slot == expectedSlot, "pool slot hash");
        bytes memory result = data;
        if (fails) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        assembly ("memory-safe") { return(add(result, 32), mload(result)) }
    }
}
contract DescriptorAsset {
    bytes symbolData;
    bytes decimalsData;
    bool fails;
    function configure(bytes memory symbol, bytes memory decimals, bool failure) external {
        symbolData = symbol; decimalsData = decimals; fails = failure;
    }
    fallback(bytes calldata input) external returns (bytes memory) {
        bytes memory result = bytes4(input) == bytes4(keccak256("symbol()")) ? symbolData : decimalsData;
        if (fails) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        return result;
    }
}
contract DescriptorDelegateCaller {
    function invoke(address target, bytes memory data) external returns (bool, bytes memory) {
        return target.delegatecall(data);
    }
}
contract PositionDescriptorParityTest {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes code;
    address fe;
    PositionDescriptor sol;
    DescriptorPositionData positions;
    DescriptorPoolData pool;
    DescriptorAsset asset0;
    DescriptorAsset asset1;
    PoolKey key;

    function deploy(bytes memory creation) internal returns (address a) {
        assembly ("memory-safe") { a := create(0, add(creation, 32), mload(creation)) }
        require(a.code.length > 0, "deployment");
    }
    function setUp() public {
        code = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        positions = new DescriptorPositionData(); pool = new DescriptorPoolData();
        asset0 = new DescriptorAsset(); asset1 = new DescriptorAsset();
        asset0.configure(abi.encode("BASE"), abi.encode(uint8(18)), false);
        asset1.configure(abi.encode("QUOTE"), abi.encode(uint8(6)), false);
        key = PoolKey(Currency.wrap(address(asset0)), Currency.wrap(address(asset1)), 3000, 60, IHooks(address(0)));
        // IHooks is erased to address in the external ABI but not in Solidity source.
        install(1, -120, 120, 0);
        pair(address(asset0), bytes32("ETH"));
    }
    function pair(address wrapped, bytes32 label) internal {
        fe = deploy(bytes.concat(code, abi.encode(address(pool), wrapped, label)));
        sol = new PositionDescriptor(IPoolManager(address(pool)), wrapped, label);
    }
    function install(uint256, int24 lower, int24 upper, int24 current) internal {
        PositionInfo info = PositionInfoLibrary.initialize(key, lower, upper);
        positions.configure(abi.encode(key, info), false);
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(6)));
        pool.configure(slot, abi.encode(bytes32(uint256(uint24(current)) << 160)), false);
    }
    function compare(bytes memory data, bool mustSucceed) internal view returns (bytes memory x) {
        bool a; (a, x) = fe.staticcall(data);
        (bool b, bytes memory y) = address(sol).staticcall(data);
        require(!mustSucceed || b, "reference must succeed");
        require(a == b, "descriptor status");
        require(keccak256(x) == keccak256(y), "descriptor bytes");
    }
    function uri(uint256 id, bool mustSucceed) internal view {
        compare(abi.encodeCall(sol.tokenURI, (IPositionManager(address(positions)), id)), mustSucceed);
    }
    function testFuzz_configuration(address wrapped, bytes32 label, address currency0, address currency1, uint64 chain) public {
        pair(wrapped, label); vm.chainId(chain);
        compare(abi.encodeCall(sol.poolManager, ()), true);
        compare(abi.encodeCall(sol.wrappedNative, ()), true);
        compare(abi.encodeCall(sol.nativeCurrencyLabel, ()), true);
        compare(abi.encodeCall(sol.currencyRatioPriority, (currency0)), true);
        compare(abi.encodeCall(sol.currencyRatioPriority, (wrapped)), true);
        compare(abi.encodeCall(sol.flipRatio, (currency0, currency1)), true);
    }
    function testFuzz_tokenURI(uint64 id, int24 current, bool native, bool reverse, uint24 fee) public {
        key.fee = fee;
        if (native) { if (reverse) key.currency1 = Currency.wrap(address(0)); else key.currency0 = Currency.wrap(address(0)); }
        install(id, -120, 120, current);
        uri(id, id != 0);
    }
    function testFuzz_externalReturns(bytes memory returned, bool fails, uint8 source) public {
        source %= 4;
        if (source == 0) positions.configure(returned, fails);
        if (source == 1) pool.configure(keccak256(abi.encode(key.toId(), uint256(6))), returned, fails);
        if (source == 2) asset0.configure(returned, abi.encode(uint8(18)), fails);
        if (source == 3) asset1.configure(abi.encode("QUOTE"), returned, fails);
        uri(1, false);
    }
    function test_priorityMatrixAndLabels() public {
        address[8] memory currencies = [address(0), address(asset0),
            address(bytes20(hex"a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")),
            address(bytes20(hex"dac17f958d2ee523a2206206994597c13d831ec7")),
            address(bytes20(hex"6b175474e89094c44da98b954eedeac495271d0f")),
            address(bytes20(hex"8daebade922df735c38c80c7ebd708af50815faa")),
            address(bytes20(hex"2260fac5e5542a773aa44fbcfedf7c193bc2c599")), address(123)];
        for (uint256 chain = 1; chain <= 2; ++chain) {
            vm.chainId(chain);
            for (uint256 i; i < currencies.length; ++i) {
                compare(abi.encodeCall(sol.currencyRatioPriority, (currencies[i])), true);
                for (uint256 j; j < currencies.length; ++j)
                    compare(abi.encodeCall(sol.flipRatio, (currencies[i], currencies[j])), true);
            }
        }
        for (uint256 n; n <= 32; ++n) {
            bytes32 label = n == 32 ? bytes32(type(uint256).max) : bytes32(type(uint256).max << ((32 - n) * 8));
            pair(currencies[2], label); vm.chainId(1);
            compare(abi.encodeCall(sol.nativeCurrencyLabel, ()), true);
            compare(abi.encodeCall(sol.currencyRatioPriority, (currencies[2])), true);
        }
    }
    function test_invalidIdAndReturnBoundaries() public {
        // A low subscriber/tick payload without high pool-id bits is invalid.
        for (uint256 info; info < 3; ++info) {
            positions.configure(abi.encode(key, info == 0 ? 0 : info == 1 ? type(uint56).max : uint256(1) << 56), false);
            uri(123, info == 2);
        }
        pool.configure(keccak256(abi.encode(key.toId(), uint256(6))), hex"abcd", true);
        positions.configure(abi.encode(key, uint256(1)), false); uri(123, false);
        install(1, -120, 120, 0);
        for (uint256 n; n < 192; ++n) { positions.configure(new bytes(n), false); uri(1, false); }
        install(1, -120, 120, 0);
        compare(abi.encodeCall(sol.tokenURI, (IPositionManager(address(12345)), 1)), false);
        positions.configure(hex"0000000000000000000000000000000000000000000000000000000000000001", true);
        uri(1, false);
    }
    function test_metadataAndTickBoundaries() public {
        key.currency0 = Currency.wrap(address(0));
        int24[5] memory ticks = [int24(-121), -120, 0, 120, 121];
        for (uint256 i; i < ticks.length; ++i) { install(1, -120, 120, ticks[i]); uri(1, true); }
        key.tickSpacing = 1; install(1, -887272, 887272, 0); uri(1, true);
        asset1.configure(abi.encode(bytes32("A\x00B")), abi.encode(uint256(256)), false); uri(1, true);
        asset1.configure(abi.encode("LONG_CURRENCY_SYMBOL"), hex"", false); uri(1, true);
        uri(0, false); uri(type(uint256).max, false);
    }
    function test_delegatecallUsesConstructorConfiguration() public {
        DescriptorDelegateCaller caller = new DescriptorDelegateCaller();
        bytes[4] memory calls = [abi.encodeCall(sol.poolManager, ()),
            abi.encodeCall(sol.wrappedNative, ()), abi.encodeCall(sol.nativeCurrencyLabel, ()),
            abi.encodeCall(sol.tokenURI, (IPositionManager(address(positions)), 1))];
        for (uint256 i; i < calls.length; ++i) {
            (bool a, bytes memory x) = caller.invoke(fe, calls[i]);
            (bool b, bytes memory y) = caller.invoke(address(sol), calls[i]);
            require(a && b && keccak256(x) == keccak256(y), "immutable delegatecall");
        }
    }
    function test_dispatchAndValueGuards() public {
        compare(hex"", false); compare(hex"01", false); compare(hex"deadbeef", false);
        bytes memory full = abi.encodeCall(sol.tokenURI, (IPositionManager(address(positions)), 1));
        for (uint256 n = 4; n < full.length; ++n) {
            bytes memory truncated = new bytes(n);
            for (uint256 i; i < n; ++i) truncated[i] = full[i];
            compare(truncated, false);
        }
        assembly ("memory-safe") { mstore(add(full, 36), shl(160, 1)) }
        compare(full, false);
        vm.deal(address(this), 1);
        bytes memory data = abi.encodeCall(sol.nativeCurrencyLabel, ());
        (bool a, bytes memory x) = fe.call{value: 1}(data);
        (bool b, bytes memory y) = address(sol).call{value: 1}(data);
        require(!a && !b && keccak256(x) == keccak256(y), "nonpayable guard");
    }
}
