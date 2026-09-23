// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Multicall_v4} from "./periphery/src/base/Multicall_v4.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function load(address,bytes32) external view returns(bytes32);
}
contract SolidityMulticall is Multicall_v4 {
    uint256 public counter;
    function bump(uint256 n) external payable returns(address,uint256,uint256){counter+=n;return(msg.sender,msg.value,counter);}
    function echo(bytes calldata data) external pure returns(bytes memory){return data;}
    function fail(bytes memory data) external payable {assembly {revert(add(data,32),mload(data))}}
}
contract MulticallParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityMulticall sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;
        sol=new SolidityMulticall();vm.deal(address(this),100 ether);
    }
    function compare(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out){
        (ok,out)=fe.call{value:value}(data);(bool refOk,bytes memory expected)=address(sol).call{value:value}(data);
        require(ok==refOk,"multicall status");require(keccak256(out)==keccak256(expected),"multicall result");
        require(vm.load(fe,0)==vm.load(address(sol),0),"state rollback");require(fe.balance==address(sol).balance,"value rollback");
    }
    function testFuzz_stateAndContext(uint128 a,uint128 b,uint64 value,bool nested) public {
        bytes[] memory data=new bytes[](2);data[0]=abi.encodeCall(sol.bump,(a));data[1]=abi.encodeCall(sol.bump,(b));
        bytes memory input=abi.encodeCall(sol.multicall,(data));
        if(nested){bytes[] memory outer=new bytes[](1);outer[0]=input;input=abi.encodeCall(sol.multicall,(outer));}
        (bool ok,)=compare(input,value);require(ok,"state calls");require(sol.counter()==uint256(a)+b);
    }
    function testFuzz_returns(bytes memory a,bytes memory b,bool trim) public {
        bytes[] memory data=new bytes[](3);data[0]=abi.encodeCall(sol.echo,(a));data[1]=abi.encodeCall(sol.echo,(b));data[2]=abi.encodeCall(sol.echo,(bytes("")));
        if(trim){uint256 n=68+b.length;bytes memory value=data[1];assembly {mstore(value,n)}}
        (bool ok,)=compare(abi.encodeCall(sol.multicall,(data)),0);require(ok,"echo calls");
    }
    function testFuzz_rollback(bytes memory reason,uint64 value) public {
        bytes[] memory data=new bytes[](3);data[0]=abi.encodeCall(sol.bump,(1));data[1]=abi.encodeCall(sol.fail,(reason));data[2]=abi.encodeCall(sol.bump,(2));
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.multicall,(data)),value);require(!ok);require(keccak256(out)==keccak256(reason));require(sol.counter()==0);
    }
    function test_emptyAndNonpayable() public {
        bytes[] memory data=new bytes[](0);(bool ok,)=compare(abi.encodeCall(sol.multicall,(data)),1);require(ok);
        data=new bytes[](1);data[0]=abi.encodeCall(sol.echo,(bytes("")));(ok,)=compare(abi.encodeCall(sol.multicall,(data)),1);require(!ok);
    }
    function testFuzz_decoderOrder(bytes memory reason, bool firstReverts) public {
        bytes[] memory calls=new bytes[](2);
        calls[0]=firstReverts ? abi.encodeCall(sol.fail,(reason)) : abi.encodeCall(sol.bump,(1));
        calls[1]=abi.encodeCall(sol.echo,(bytes("second")));
        bytes memory data=abi.encodeCall(sol.multicall,(calls));
        // The second payload must be checked only after the first call.
        assembly {mstore(add(data,132),0xffff)}
        (bool ok,bytes memory result)=compare(data,0);
        require(!ok);
        require(keccak256(result)==keccak256(firstReverts ? reason : bytes("")));
        require(sol.counter()==0);
    }

}
