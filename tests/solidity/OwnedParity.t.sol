// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;
import {Owned} from "./reference/src/auth/Owned.sol";
interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
    function prank(address) external;
    function load(address,bytes32) external view returns(bytes32);
    function store(address,bytes32,bytes32) external;
}
contract SolidityOwnedHarness is Owned {
    constructor(address initialOwner) Owned(initialOwner) {}
    function restricted() external view onlyOwner returns(bool) { return true; }
}
contract OwnedParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityOwnedHarness sol;
    function logsEqual(Vm.Log[] memory a,Vm.Log[] memory b) internal view {
        require(a.length==b.length,"event count");
        for(uint256 i;i<a.length;i++) {
            require(a[i].emitter==fe && b[i].emitter==address(sol),"event emitter");
            require(keccak256(abi.encode(a[i].topics,a[i].data))==keccak256(abi.encode(b[i].topics,b[i].data)),"event fields");
        }
    }
    function deploy(address initial) internal {
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(initial));
        vm.recordLogs();address deployed;assembly ("memory-safe") { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"Fe deploy");fe=deployed;Vm.Log[] memory a=vm.getRecordedLogs();
        vm.recordLogs();sol=new SolidityOwnedHarness(initial);Vm.Log[] memory b=vm.getRecordedLogs();logsEqual(a,b);
        require(a.length==1 && a[0].topics.length==3 && a[0].topics[0]==keccak256("OwnershipTransferred(address,address)") && a[0].topics[1]==0 && a[0].topics[2]==bytes32(uint256(uint160(initial))),"constructor event");
        require(vm.load(fe,0)==bytes32(uint256(uint160(initial))) && vm.load(fe,0)==vm.load(address(sol),0),"constructor slot");
    }
    function compare(address caller,bytes memory data) internal returns(bool ok,bytes memory out) {
        vm.recordLogs();vm.prank(caller);(ok,out)=fe.call(data);Vm.Log[] memory a=vm.getRecordedLogs();
        vm.recordLogs();vm.prank(caller);(bool b,bytes memory expected)=address(sol).call(data);Vm.Log[] memory c=vm.getRecordedLogs();
        require(ok==b && keccak256(out)==keccak256(expected),"result mismatch");logsEqual(a,c);
        require(vm.load(fe,0)==vm.load(address(sol),0),"owner slot mismatch");
    }
    function testFuzz_ownership(address initial,address next,address outsider,uint96 reserved) public {
        deploy(initial);bytes32 word=bytes32((uint256(reserved)<<160)|uint160(initial));vm.store(fe,0,word);vm.store(address(sol),0,word);
        (bool ok,bytes memory out)=compare(outsider,abi.encodeCall(sol.restricted,()));
        require(ok==(outsider==initial),"authorization");
        if(!ok)require(keccak256(out)==keccak256(abi.encodeWithSignature("Error(string)","UNAUTHORIZED")),"require string");
        compare(outsider,abi.encodeCall(sol.transferOwnership,(next)));
        address current=outsider==initial?next:initial;
        (ok,)=compare(current,abi.encodeCall(sol.transferOwnership,(next)));require(ok,"owner transfer");
        require(uint256(vm.load(fe,0))==((uint256(reserved)<<160)|uint160(next)),"reserved owner slot bits");
        (ok,out)=fe.staticcall(abi.encodeCall(sol.owner,()));require(ok && abi.decode(out,(address))==next,"static owner getter");
        (ok,)=compare(next,abi.encodeCall(sol.restricted,()));require(ok,"new owner rights");
        vm.prank(next);(ok,out)=fe.staticcall(abi.encodeCall(sol.restricted,()));require(ok && abi.decode(out,(bool)),"static restricted");
        compare(initial,abi.encodeCall(sol.restricted,()));
    }
    function test_zeroAndSelfOwnership() public {
        testFuzz_ownership(address(0),address(0),address(1),type(uint96).max);
        testFuzz_ownership(address(1),address(0),address(1),0);
        testFuzz_ownership(address(1),address(1),address(1),type(uint96).max);
    }
}
