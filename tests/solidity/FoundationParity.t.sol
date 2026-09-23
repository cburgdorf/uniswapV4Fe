// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {LPFeeLibrary} from "./reference/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "./reference/src/libraries/ProtocolFeeLibrary.sol";
import {LiquidityMath} from "./reference/src/libraries/LiquidityMath.sol";
import {FixedPoint96} from "./reference/src/libraries/FixedPoint96.sol";
import {FixedPoint128} from "./reference/src/libraries/FixedPoint128.sol";
import {BalanceDelta, toBalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "./reference/src/types/BeforeSwapDelta.sol";
import {Slot0} from "./reference/src/types/Slot0.sol";

interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
}
contract SolidityFoundationHarness {
    function lpInfo(uint24 fee) external pure returns (bool, bool, bool, uint24) {
        return (LPFeeLibrary.isDynamicFee(fee), LPFeeLibrary.isValid(fee), LPFeeLibrary.isOverride(fee), LPFeeLibrary.removeOverrideFlag(fee));
    }
    function lpChecked(uint24 fee, uint8 mode) external pure returns (uint24) {
        if (mode == 0) { LPFeeLibrary.validate(fee); return fee; }
        if (mode == 1) return LPFeeLibrary.getInitialLPFee(fee);
        return LPFeeLibrary.removeOverrideFlagAndValidate(fee);
    }
    function protocolInfo(uint24 fee) external pure returns (uint16, uint16, bool) {
        return (ProtocolFeeLibrary.getZeroForOneFee(fee), ProtocolFeeLibrary.getOneForZeroFee(fee), ProtocolFeeLibrary.isValidProtocolFee(fee));
    }
    function combinedFee(uint16 protocol, uint24 lp) external pure returns (uint24) {
        return ProtocolFeeLibrary.calculateSwapFee(protocol, lp);
    }
    function addLiquidity(uint128 liquidity, int128 delta) external pure returns (uint128) { return LiquidityMath.addDelta(liquidity, delta); }
    function packDelta(int128 a, int128 b) external pure returns (int256, int256) {
        return (BalanceDelta.unwrap(toBalanceDelta(a,b)), BeforeSwapDelta.unwrap(toBeforeSwapDelta(a,b)));
    }
    function unpackDelta(int256 value) external pure returns (int128, int128, int128, int128) {
        return (BalanceDelta.wrap(value).amount0(), BalanceDelta.wrap(value).amount1(),
            BeforeSwapDeltaLibrary.getSpecifiedDelta(BeforeSwapDelta.wrap(value)), BeforeSwapDeltaLibrary.getUnspecifiedDelta(BeforeSwapDelta.wrap(value)));
    }
    function deltaArithmetic(int256 a, int256 b, bool subtract) external pure returns (int256, bool, bool) {
        BalanceDelta left = BalanceDelta.wrap(a);
        BalanceDelta right = BalanceDelta.wrap(b);
        return (BalanceDelta.unwrap(subtract ? left - right : left + right), left == right, left != right);
    }
    function slotRead(uint256 value) external pure returns (uint160, int24, uint24, uint24) {
        Slot0 slot = Slot0.wrap(bytes32(value));
        return (slot.sqrtPriceX96(), slot.tick(), slot.protocolFee(), slot.lpFee());
    }
    function slotWrite(uint256 value, uint160 price, int24 tick, uint24 fee, uint8 mode) external pure returns (uint256) {
        Slot0 slot = Slot0.wrap(bytes32(value));
        if (mode == 0) slot = slot.setSqrtPriceX96(price);
        else if (mode == 1) slot = slot.setTick(tick);
        else if (mode == 2) slot = slot.setProtocolFee(fee);
        else slot = slot.setLpFee(fee);
        return uint256(Slot0.unwrap(slot));
    }
    function fixedPointConstants() external pure returns (uint8, uint256, uint256) { return (FixedPoint96.RESOLUTION, FixedPoint96.Q96, FixedPoint128.Q128); }
}
contract FoundationParityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityFoundationHarness sol;
    function setUp() public {
        bytes memory initcode = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed;
        assembly { deployed := create(0, add(initcode, 32), mload(initcode)) }
        require(deployed.code.length != 0, "Fe deploy failed");
        fe = deployed;
        sol = new SolidityFoundationHarness();
    }
    function compare(bytes memory data) internal view returns (bytes memory) {
        (bool a, bytes memory x) = fe.staticcall(data);
        (bool b, bytes memory y) = address(sol).staticcall(data);
        require(a == b, "success/revert mismatch");
        require(keccak256(x) == keccak256(y), "return/revert mismatch");
        return x;
    }
    function testFuzz_lpFee(uint24 fee) public view {
        compare(abi.encodeCall(sol.lpInfo,(fee)));
        for (uint8 mode; mode < 3; ++mode) compare(abi.encodeCall(sol.lpChecked,(fee,mode)));
    }
    function testFuzz_protocolFee(uint24 packed, uint16 protocol, uint24 lp) public view {
        compare(abi.encodeCall(sol.protocolInfo,(packed)));
        compare(abi.encodeCall(sol.combinedFee,(protocol,lp)));
    }
    function testFuzz_liquidity(uint128 liquidity, int128 delta) public view { compare(abi.encodeCall(sol.addLiquidity,(liquidity,delta))); }
    function testFuzz_deltaPacking(int128 a, int128 b, int256 packed) public view {
        compare(abi.encodeCall(sol.packDelta,(a,b)));
        compare(abi.encodeCall(sol.unpackDelta,(packed)));
    }
    function testFuzz_deltaArithmetic(int256 a, int256 b) public view {
        compare(abi.encodeCall(sol.deltaArithmetic,(a,b,false)));
        compare(abi.encodeCall(sol.deltaArithmetic,(a,b,true)));
    }
    function testFuzz_slot0(uint256 packed, uint160 price, int24 tick, uint24 fee) public view {
        compare(abi.encodeCall(sol.slotRead,(packed)));
        for (uint8 mode; mode < 4; ++mode) {
            uint256 updated = abi.decode(compare(abi.encodeCall(sol.slotWrite,(packed,price,tick,fee,mode))), (uint256));
            compare(abi.encodeCall(sol.slotRead,(updated)));
            require(updated >> 232 == packed >> 232, "reserved bits changed");
        }
    }
    function test_boundaries() public view {
        compare(abi.encodeCall(sol.fixedPointConstants,()));
        uint24[12] memory fees = [uint24(0), 1000, 1001, 1000000, 1000001, 0x800000, 0x800001, 0x400000, 0x400001, 0x4f4240, 0xc00000, 0xffffff];
        for (uint256 i; i < fees.length; ++i) {
            compare(abi.encodeCall(sol.lpInfo,(fees[i])));
            compare(abi.encodeCall(sol.protocolInfo,(fees[i])));
            for (uint8 mode; mode < 3; ++mode) compare(abi.encodeCall(sol.lpChecked,(fees[i],mode)));
        }
        uint16[6] memory protocols = [uint16(0), 1000, 1001, 4095, 4096, 65535];
        for (uint256 i; i < protocols.length; ++i) {
            for (uint256 j; j < fees.length; ++j) compare(abi.encodeCall(sol.combinedFee,(protocols[i],fees[j])));
        }
        int128[5] memory deltas = [type(int128).min, int128(-1), 0, 1, type(int128).max];
        uint128[4] memory liquidities = [uint128(0), 1, 1 << 127, type(uint128).max];
        for (uint256 i; i < deltas.length; ++i) {
            for (uint256 j; j < liquidities.length; ++j) compare(abi.encodeCall(sol.addLiquidity,(liquidities[j],deltas[i])));
            for (uint256 j; j < deltas.length; ++j) {
                compare(abi.encodeCall(sol.packDelta,(deltas[i],deltas[j])));
                int256 packed = BalanceDelta.unwrap(toBalanceDelta(deltas[i],deltas[j]));
                compare(abi.encodeCall(sol.unpackDelta,(packed)));
                compare(abi.encodeCall(sol.deltaArithmetic,(packed,packed,false)));
                compare(abi.encodeCall(sol.deltaArithmetic,(packed,packed,true)));
                compare(abi.encodeCall(sol.deltaArithmetic,(packed,int256(0),false)));
            }
        }
        for (uint256 bit; bit < 256; ++bit) compare(abi.encodeCall(sol.slotRead,(uint256(1) << bit)));
        int24[5] memory ticks = [type(int24).min, int24(-1), 0, 1, type(int24).max];
        for (uint256 i; i < ticks.length; ++i) {
            for (uint8 mode; mode < 4; ++mode) {
                uint256 updated = abi.decode(compare(abi.encodeCall(sol.slotWrite,(type(uint256).max,uint160(0),ticks[i],uint24(0),mode))), (uint256));
                compare(abi.encodeCall(sol.slotRead,(updated)));
            }
        }
    }
}
