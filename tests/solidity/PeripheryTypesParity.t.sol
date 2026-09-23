// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PositionInfo,PositionInfoLibrary} from "./periphery/src/libraries/PositionInfoLibrary.sol";
import {PathKey,PathKeyLibrary} from "./periphery/src/libraries/PathKey.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract SolidityPeripheryTypes {
    function info(uint256 bits) external pure returns(bytes32,int24,int24,bool,uint256,uint256) {
        PositionInfo p=PositionInfo.wrap(bits);
        return (bytes32(p.poolId()),p.tickLower(),p.tickUpper(),p.hasSubscriber(),PositionInfo.unwrap(p.setSubscribe()),PositionInfo.unwrap(p.setUnsubscribe()));
    }
    function initializeInfo(PoolKey memory key,int24 lower,int24 upper) external pure returns(uint256) {
        return PositionInfo.unwrap(PositionInfoLibrary.initialize(key,lower,upper));
    }
    function fromPath(PathKey calldata p,Currency input) external pure returns(PoolKey memory,bool) {return p.getPoolAndSwapDirection(input);}
    function path(address input,address output,uint24 fee,int24 spacing,address hooks,bytes memory data) external view returns(PoolKey memory,bool) {
        return this.fromPath(PathKey(Currency.wrap(output),fee,spacing,IHooks(hooks),data),Currency.wrap(input));
    }
}
contract PeripheryTypesParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityPeripheryTypes sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address deployed;
        assembly {deployed:=create(0,add(code,32),mload(code))} require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityPeripheryTypes();
    }
    function compare(bytes memory data) internal view returns(bytes memory out) {
        (bool ok,bytes memory result)=fe.staticcall(data);(bool other,bytes memory expected)=address(sol).staticcall(data);
        require(ok && other,"valid inputs");require(keccak256(result)==keccak256(expected),"return parity");return result;
    }
    function testFuzz_info(uint256 bits) public view {compare(abi.encodeCall(sol.info,(bits)));}
    function testFuzz_initialize(address a,address b,uint24 fee,int24 spacing,address hooks,int24 lower,int24 upper) public view {
        PoolKey memory key=PoolKey(Currency.wrap(a),Currency.wrap(b),fee,spacing,IHooks(hooks));
        compare(abi.encodeCall(sol.initializeInfo,(key,lower,upper)));
    }
    function testFuzz_path(address input,address output,uint24 fee,int24 spacing,address hooks,bytes memory data) public view {
        compare(abi.encodeCall(sol.path,(input,output,fee,spacing,hooks,data)));
    }
    function test_boundaries() public view {
        compare(abi.encodeCall(sol.info,(type(uint256).max)));
        compare(abi.encodeCall(sol.info,(uint256(0x800000)<<8)));
        compare(abi.encodeCall(sol.info,(uint256(0x800000)<<32)));
        compare(abi.encodeCall(sol.info,(uint256(254))));
        bytes memory out=compare(abi.encodeCall(sol.path,(address(7),address(7),uint24(0),int24(0),address(0),bytes(""))));
        (PoolKey memory key,bool direction)=abi.decode(out,(PoolKey,bool));require(direction && Currency.unwrap(key.currency0)==address(7),"equal-currency direction");
    }
}
