// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionConfig,PositionConfigLibrary} from "./periphery/src/libraries/PositionConfig.sol";
import {PositionConfigId,PositionConfigIdLibrary} from "./periphery/src/libraries/PositionConfigId.sol";
import {VanityAddressLib} from "./periphery/src/libraries/VanityAddressLib.sol";
import {AddressStringUtil} from "./periphery/src/libraries/AddressStringUtil.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);function load(address,bytes32) external view returns(bytes32);}
contract AuxReference {
    function ascii(address a,uint256 len) external pure returns(string memory){return AddressStringUtil.toAsciiString(a,len);}
    using PositionConfigIdLibrary for PositionConfigId;
    PositionConfigId stored;
    function hash(PositionConfig calldata p) external pure returns(bytes32){return PositionConfigLibrary.toId(p);}
    function config(PoolKey memory key,int24 lower,int24 upper) external view returns(bytes32){return this.hash(PositionConfig(key,lower,upper));}
    function state(bytes32 id) external returns(bytes32,bool,bytes32,bool,bytes32,bool) {
        stored.setConfigId(id);bytes32 a=stored.getConfigId();bool b=stored.hasSubscriber();
        stored.setSubscribe();bytes32 c=stored.getConfigId();bool d=stored.hasSubscriber();
        stored.setUnsubscribe();return(a,b,c,d,stored.getConfigId(),stored.hasSubscriber());
    }
    function score(address a,address b) external pure returns(uint256,uint256,bool){return(VanityAddressLib.score(a),VanityAddressLib.score(b),VanityAddressLib.betterThan(a,b));}
    function nibble(address a,uint256 index) external pure returns(uint8){return VanityAddressLib.getNibble(bytes20(a),index);}
    function leading(address a,uint256 start,uint8 comparison) external pure returns(uint256){return VanityAddressLib.getLeadingNibbleCount(bytes20(a),start,comparison);}
}
contract PeripheryAuxParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;AuxReference sol;
    function setUp() public {bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address a;assembly("memory-safe"){a:=create(0,add(code,32),mload(code))}require(a.code.length>0);fe=a;sol=new AuxReference();}
    function compare(bytes memory data) internal { (bool a,bytes memory x)=fe.call(data);(bool b,bytes memory y)=address(sol).call(data);require(a==b&&keccak256(x)==keccak256(y),"result parity");require(vm.load(fe,0)==vm.load(address(sol),0),"storage parity");}
    function testFuzz_config(address a,address b,uint24 fee,int24 spacing,address hooks,int24 lower,int24 upper) public {compare(abi.encodeCall(sol.config,(PoolKey(Currency.wrap(a),Currency.wrap(b),fee,spacing,IHooks(hooks)),lower,upper)));}
    function testFuzz_ascii(address a,uint256 len) public {compare(abi.encodeCall(sol.ascii,(a,len)));compare(abi.encodeCall(sol.ascii,(a,(len%20+1)*2)));}
    function testFuzz_state(bytes32 id) public {compare(abi.encodeCall(sol.state,(id)));}
    function testFuzz_vanity(address a,address b,uint256 index,uint8 value) public {compare(abi.encodeCall(sol.score,(a,b)));compare(abi.encodeCall(sol.nibble,(a,index)));compare(abi.encodeCall(sol.leading,(a,index,value)));}
    function test_scoreBoundaries() public {
        compare(abi.encodeCall(sol.score,(address(0),address(0x4444))));
        for(uint256 i=0;i<40;i++){address a=address(uint160(uint256(0x44444)<<(i*4)));compare(abi.encodeCall(sol.score,(a,address(0x4444))));compare(abi.encodeCall(sol.nibble,(a,i)));compare(abi.encodeCall(sol.leading,(a,0,0)));}
    }
}
