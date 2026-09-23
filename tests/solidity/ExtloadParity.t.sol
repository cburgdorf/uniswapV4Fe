// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Extsload} from "./reference/src/Extsload.sol";
import {Exttload} from "./reference/src/Exttload.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
}
contract SolidityExtloadHarness is Extsload,Exttload {
    function write(bytes32 slot,bytes32 value,bool transient) external {
        if(transient) { assembly {tstore(slot,value)} } else { assembly {sstore(slot,value)} }
    }
}
contract ExtloadParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityExtloadHarness sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed; assembly {deployed:=create(0,add(code,32),mload(code))}
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityExtloadHarness();
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall{gas:2000000}(data);
        (bool other,bytes memory expected)=address(sol).staticcall{gas:2000000}(data);
        require(ok==other,"success mismatch");require(keccak256(out)==keccak256(expected),"return/revert mismatch");
    }
    function write(bytes32 slot,bytes32 value,bool transient) internal {
        (bool ok,)=fe.call(abi.encodeCall(sol.write,(slot,value,transient)));require(ok,"Fe write");sol.write(slot,value,transient);
    }
    function testFuzz_single(bytes32 slot,bytes32 persistent,bytes32 temporary) public {
        write(slot,persistent,false);write(slot,temporary,true);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("extsload(bytes32)",slot));require(ok && abi.decode(out,(bytes32))==persistent,"sload model");
        (ok,out)=compare(abi.encodeWithSignature("exttload(bytes32)",slot));require(ok && abi.decode(out,(bytes32))==temporary,"tload model");
    }
    function testFuzz_range(bytes32 start,uint8 length,bytes32 seed) public {
        uint256 n=length%33;bytes32[] memory expected=new bytes32[](n);
        for(uint256 i;i<n;i++) {bytes32 slot;unchecked{slot=bytes32(uint256(start)+i);}expected[i]=keccak256(abi.encode(seed,i));write(slot,expected[i],false);}
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("extsload(bytes32,uint256)",start,n));
        require(ok && keccak256(out)==keccak256(abi.encode(expected)),"range model");
    }
    function testFuzz_sparse(bytes32 seed,uint8 length,bool transient) public {
        uint256 n=length%33;bytes32[] memory slots=new bytes32[](n);bytes32[] memory expected=new bytes32[](n);
        for(uint256 i;i<n;i++) {slots[i]=keccak256(abi.encode(seed,i%7));write(slots[i],bytes32(i+100),transient);}
        for(uint256 i;i<n;i++) {uint256 last=i%7;while(last+7<n)last+=7;expected[i]=bytes32(last+100);}
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature(transient?"exttload(bytes32[])":"extsload(bytes32[])",slots));
        require(ok && keccak256(out)==keccak256(abi.encode(expected)),"sparse model");
    }
    function testFuzz_wrappedLength(uint8 high,uint8 length,bytes32 start) public {
        uint256 n=length%17;uint256 count=(uint256(high%32)<<251)|n;
        bytes32[] memory expected=new bytes32[](n);
        for(uint256 i;i<n;i++) {bytes32 slot;unchecked{slot=bytes32(uint256(start)+i);}expected[i]=bytes32(i+31);write(slot,expected[i],false);}
        bytes memory raw=abi.encode(expected);assembly {mstore(add(raw,64),count)}
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("extsload(bytes32,uint256)",start,count));
        require(ok && keccak256(out)==keccak256(raw),"wrapped length model");
    }
    function testFuzz_malformed(uint256 offset,uint256 count,uint8 bytesLength,bool transient) public view {
        bytes memory tail=new bytes(bytesLength);
        compare(bytes.concat(abi.encodePacked(bytes4(keccak256(bytes(transient?"exttload(bytes32[])":"extsload(bytes32[])")))),abi.encode(offset,count),tail));
        compare(bytes.concat(abi.encodePacked(bytes4(keccak256(bytes(transient?"exttload(bytes32[])":"extsload(bytes32[])")))),abi.encode(uint256(32),count),tail));
    }
    function test_extremeLengthsAndWraparound() public {
        testFuzz_range(bytes32(type(uint256).max-3),9,bytes32(uint256(42)));
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(0),type(uint256).max));
        require(ok && keccak256(out)==keccak256(abi.encode(uint256(32))),"minus one length");
        (ok,out)=compare(abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(0),type(uint256).max-1));require(ok && out.length==0,"minus two length");
        compare(abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(0),type(uint256).max-2));
        compare(abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(0),uint256(1)<<250));
    }
    function test_dynamicCalldataBoundaries() public view {
        bytes32[] memory slots=new bytes32[](2);slots[0]=bytes32(uint256(1));slots[1]=bytes32(uint256(2));
        for(uint256 kind;kind<2;kind++) {
            bytes memory full=abi.encodeWithSignature(kind==0?"extsload(bytes32[])":"exttload(bytes32[])",slots);
            for(uint256 n=4;n<full.length;n++) {bytes memory truncated=new bytes(n);for(uint256 i;i<n;i++)truncated[i]=full[i];compare(truncated);}
            compare(bytes.concat(full,hex"010203"));
            // Deliberately unaligned but complete ABI tail.
            bytes memory odd=bytes.concat(abi.encodePacked(bytes4(keccak256(bytes(kind==0?"extsload(bytes32[])":"exttload(bytes32[])")))),abi.encode(uint256(33)),hex"00",abi.encode(uint256(2),slots[0],slots[1]));compare(odd);
        }
    }
}
