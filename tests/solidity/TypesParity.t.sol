// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {ModifyLiquidityParams,SwapParams} from "./reference/src/types/PoolOperation.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
}
contract SolidityTypesHarness {
    function poolId(PoolKey memory key) external pure returns(bytes32) { return PoolId.unwrap(key.toId()); }
    function echoKey(PoolKey memory key) external pure returns(PoolKey memory) { return key; }
    function echoModify(ModifyLiquidityParams memory params) external pure returns(ModifyLiquidityParams memory) { return params; }
    function echoSwap(SwapParams memory params) external pure returns(SwapParams memory) { return params; }
}
contract TypesParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityTypesHarness sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed;assembly { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityTypesHarness();
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall(data);
        (bool other,bytes memory expected)=address(sol).staticcall(data);
        require(ok==other,"decode success mismatch");require(keccak256(out)==keccak256(expected),"ABI bytes mismatch");
    }
    function testFuzz_poolKey(address c0,address c1,uint24 fee,int24 spacing,address hooks) public view {
        PoolKey memory key=PoolKey(Currency.wrap(c0),Currency.wrap(c1),fee,spacing,IHooks(hooks));
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.poolId,(key)));
        require(ok && abi.decode(out,(bytes32))==keccak256(abi.encode(key)),"pool ID model");
        (ok,out)=compare(abi.encodeCall(sol.echoKey,(key)));
        require(ok && keccak256(out)==keccak256(abi.encode(key)),"key roundtrip");
    }
    function testFuzz_modify(int24 lower,int24 upper,int256 delta,bytes32 salt) public view {
        ModifyLiquidityParams memory params=ModifyLiquidityParams(lower,upper,delta,salt);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.echoModify,(params)));
        require(ok && keccak256(out)==keccak256(abi.encode(params)),"modify roundtrip");
    }
    function testFuzz_swap(bool direction,int256 amount,uint160 limit) public view {
        SwapParams memory params=SwapParams(direction,amount,limit);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.echoSwap,(params)));
        require(ok && keccak256(out)==keccak256(abi.encode(params)),"swap roundtrip");
    }
    function testFuzz_dirtyKey(uint8 field,uint256 dirty) public view {
        PoolKey memory key=PoolKey(Currency.wrap(address(1)),Currency.wrap(address(2)),3,-4,IHooks(address(5)));
        bytes memory data=abi.encodeCall(sol.poolId,(key));uint256 offset=4+32*(field%5);
        assembly { mstore(add(add(data,32),offset),dirty) }
        compare(data);
        bytes4 selector=sol.echoKey.selector;
        data[0]=selector[0];data[1]=selector[1];data[2]=selector[2];data[3]=selector[3];
        compare(data);
    }
    function testFuzz_dirtyOperations(uint8 field,uint256 dirty) public view {
        bytes memory data=abi.encodeCall(sol.echoModify,(ModifyLiquidityParams(-1,1,-1,bytes32(uint256(2)))));
        uint256 offset=4+32*(field%4);assembly { mstore(add(add(data,32),offset),dirty) }
        compare(data);
        data=abi.encodeCall(sol.echoSwap,(SwapParams(true,-1,3)));
        offset=4+32*(field%3);assembly { mstore(add(add(data,32),offset),dirty) }
        compare(data);
    }
    function test_truncationAndTrailingData() public view {
        bytes[4] memory calls=[abi.encodeCall(sol.poolId,(PoolKey(Currency.wrap(address(0)),Currency.wrap(address(0)),0,0,IHooks(address(0))))),abi.encodeCall(sol.echoKey,(PoolKey(Currency.wrap(address(0)),Currency.wrap(address(0)),0,0,IHooks(address(0))))),abi.encodeCall(sol.echoModify,(ModifyLiquidityParams(0,0,0,bytes32(0)))),abi.encodeCall(sol.echoSwap,(SwapParams(false,0,0)))];
        for(uint256 i;i<calls.length;i++) {
            bytes memory full=calls[i];
            for(uint256 len;len<full.length;len++) {
                bytes memory shortData=new bytes(len);for(uint256 j;j<len;j++) shortData[j]=full[j];
                (bool ok,)=compare(shortData);require(!ok,"truncated head accepted");
            }
            (bool ok,)=compare(bytes.concat(full,hex"deadbeef"));require(ok,"trailing data rejected");
        }
    }
    function test_boundaries() public view {
        testFuzz_poolKey(address(0),address(type(uint160).max),type(uint24).max,type(int24).min,address(0));
        testFuzz_poolKey(address(1),address(1),0,type(int24).max,address(type(uint160).max));
        testFuzz_modify(type(int24).min,type(int24).max,type(int256).min,bytes32(type(uint256).max));
        testFuzz_swap(true,type(int256).max,type(uint160).max);
        testFuzz_swap(false,type(int256).min,0);
    }
}
