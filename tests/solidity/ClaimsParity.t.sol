// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC6909Claims} from "./reference/src/ERC6909Claims.sol";
interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function store(address,bytes32,bytes32) external;
    function load(address,bytes32) external view returns(bytes32);
    function prank(address) external;
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract SolidityClaimsHarness is ERC6909Claims {
    function mint(address receiver,uint256 id,uint256 amount) external { _mint(receiver,id,amount); }
    function burn(address sender,uint256 id,uint256 amount) external { _burn(sender,id,amount); }
    function burnFrom(address sender,uint256 id,uint256 amount) external { _burnFrom(sender,id,amount); }
}
contract Prefix { uint256[3] private prefix; }
contract SolidityOffsetClaimsHarness is Prefix, SolidityClaimsHarness {}
contract ClaimsParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    struct Deployment { address fe; SolidityClaimsHarness sol; uint256 root; }
    Deployment[2] pairs;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        for(uint256 i;i<2;i++) {
            uint256 root=i*3;bytes memory initcode=bytes.concat(code,abi.encode(root));address deployed;
            assembly ("memory-safe") { deployed:=create(0,add(initcode,32),mload(initcode)) }
            require(deployed.code.length>0,"Fe deploy");
            SolidityClaimsHarness sol=i==0?new SolidityClaimsHarness():new SolidityOffsetClaimsHarness();
            pairs[i]=Deployment(deployed,sol,root);
        }
    }
    function balanceSlot(Deployment memory p,address owner,uint256 id) internal pure returns(bytes32) { return keccak256(abi.encode(id,keccak256(abi.encode(owner,p.root+1)))); }
    function operatorSlot(Deployment memory p,address owner,address operator) internal pure returns(bytes32) { return keccak256(abi.encode(operator,keccak256(abi.encode(owner,p.root)))); }
    function allowanceSlot(Deployment memory p,address owner,address spender,uint256 id) internal pure returns(bytes32) { return keccak256(abi.encode(id,keccak256(abi.encode(spender,keccak256(abi.encode(owner,p.root+2)))))); }
    function seed(Deployment memory p,bytes32 slot,uint256 value) internal { vm.store(p.fe,slot,bytes32(value));vm.store(address(p.sol),slot,bytes32(value)); }
    function sameSlot(Deployment memory p,bytes32 slot) internal view returns(uint256 value) {
        bytes32 a=vm.load(p.fe,slot);require(a==vm.load(address(p.sol),slot),"storage mismatch");return uint256(a);
    }
    function compare(Deployment memory p,address caller,bytes memory data) internal returns(bool ok,bytes memory out,Vm.Log[] memory logs) {
        vm.recordLogs();vm.prank(caller);(ok,out)=p.fe.call(data);logs=vm.getRecordedLogs();
        vm.recordLogs();vm.prank(caller);(bool other,bytes memory expected)=address(p.sol).call(data);Vm.Log[] memory expectedLogs=vm.getRecordedLogs();
        require(ok==other,"success mismatch");require(keccak256(out)==keccak256(expected),"return/revert mismatch");
        require(logs.length==expectedLogs.length,"log count mismatch");
        for(uint256 i;i<logs.length;i++) {
            require(logs[i].emitter==p.fe && expectedLogs[i].emitter==address(p.sol),"log emitter");
            require(keccak256(abi.encode(logs[i].topics))==keccak256(abi.encode(expectedLogs[i].topics)),"log topics");
            require(keccak256(logs[i].data)==keccak256(expectedLogs[i].data),"log data");
        }
    }
    function transferLog(Vm.Log[] memory logs,address caller,address from,address to,uint256 id,uint256 amount) internal pure {
        require(logs.length==1 && logs[0].topics.length==4,"one transfer log");
        require(logs[0].topics[0]==keccak256("Transfer(address,address,address,uint256,uint256)"),"Transfer signature");
        require(logs[0].topics[1]==bytes32(uint256(uint160(from))) && logs[0].topics[2]==bytes32(uint256(uint160(to))) && logs[0].topics[3]==bytes32(id),"indexed fields");
        require(keccak256(logs[0].data)==keccak256(abi.encode(caller,amount)),"nonindexed fields");
    }
    function testFuzz_transfer(address sender,address receiver,uint256 id,uint256 balance,uint256 recipientBalance,uint256 amount) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];bytes32 from=balanceSlot(p,sender,id);bytes32 to=balanceSlot(p,receiver,id);
            seed(p,to,recipientBalance);seed(p,from,balance);
            (bool ok,,Vm.Log[] memory logs)=compare(p,sender,abi.encodeCall(p.sol.transfer,(receiver,id,amount)));
            bool expected=amount<=balance && (sender==receiver || amount<=type(uint256).max-recipientBalance);
            require(ok==expected,"transfer model");
            if(ok) {
                require(sameSlot(p,from)==(sender==receiver?balance:balance-amount),"sender balance");
                require(sameSlot(p,to)==(sender==receiver?balance:recipientBalance+amount),"receiver balance");
                transferLog(logs,sender,sender,receiver,id,amount);
            } else { require(sameSlot(p,from)==balance,"sender rollback");sameSlot(p,to);require(logs.length==0,"reverted logs"); }
        }
    }
    function testFuzz_transferFrom(address owner,address spender,address receiver,uint256 id,uint256 balance,uint256 allowed,uint256 amount,bool operator) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];bytes32 from=balanceSlot(p,owner,id);bytes32 to=balanceSlot(p,receiver,id);bytes32 approval=allowanceSlot(p,owner,spender,id);
            seed(p,to,0);seed(p,from,balance);seed(p,approval,allowed);seed(p,operatorSlot(p,owner,spender),operator?1:0);
            (bool ok,,Vm.Log[] memory logs)=compare(p,spender,abi.encodeCall(p.sol.transferFrom,(owner,receiver,id,amount)));
            bool bypass=spender==owner || operator;
            bool expected=amount<=balance && (bypass || amount<=allowed);
            require(ok==expected,"transferFrom model");
            require(sameSlot(p,approval)==(ok && !bypass && allowed!=type(uint256).max?allowed-amount:allowed),"allowance consumption/rollback");
            require(sameSlot(p,from)==(ok && owner!=receiver?balance-amount:balance),"owner balance");sameSlot(p,to);
            if(ok)transferLog(logs,spender,owner,receiver,id,amount);
        }
    }
    function testFuzz_mintBurn(address owner,address caller,uint256 id,uint256 balance,uint256 amount) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];bytes32 slot=balanceSlot(p,owner,id);seed(p,slot,balance);
            (bool ok,,Vm.Log[] memory logs)=compare(p,caller,abi.encodeCall(p.sol.mint,(owner,id,amount)));
            require(ok==(amount<=type(uint256).max-balance),"mint overflow");
            require(sameSlot(p,slot)==(ok?balance+amount:balance),"mint balance");if(ok)transferLog(logs,caller,address(0),owner,id,amount);
            seed(p,slot,balance);
            (ok,,logs)=compare(p,caller,abi.encodeCall(p.sol.burn,(owner,id,amount)));
            require(ok==(amount<=balance),"burn underflow");require(sameSlot(p,slot)==(ok?balance-amount:balance),"burn balance");if(ok)transferLog(logs,caller,owner,address(0),id,amount);
        }
    }
    function testFuzz_burnFrom(address owner,address spender,uint256 id,uint256 balance,uint256 allowed,uint256 amount,bool operator) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];bytes32 slot=balanceSlot(p,owner,id);bytes32 approval=allowanceSlot(p,owner,spender,id);
            seed(p,slot,balance);seed(p,approval,allowed);seed(p,operatorSlot(p,owner,spender),operator?1:0);
            (bool ok,,Vm.Log[] memory logs)=compare(p,spender,abi.encodeCall(p.sol.burnFrom,(owner,id,amount)));
            bool bypass=owner==spender || operator;require(ok==(amount<=balance && (bypass || amount<=allowed)),"burnFrom authorization");
            require(sameSlot(p,slot)==(ok?balance-amount:balance),"burnFrom balance");
            require(sameSlot(p,approval)==(ok && !bypass && allowed!=type(uint256).max?allowed-amount:allowed),"burnFrom allowance");
            if(ok)transferLog(logs,spender,owner,address(0),id,amount);
        }
    }
    function testFuzz_approvalOperatorGetters(address owner,address spender,uint256 id,uint256 amount,uint256 dirty,bool approved) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];bytes32 slot=operatorSlot(p,owner,spender);seed(p,slot,dirty);
            compare(p,owner,abi.encodeCall(p.sol.isOperator,(owner,spender)));
            (bool ok,bytes memory result,Vm.Log[] memory logs)=compare(p,owner,abi.encodeCall(p.sol.setOperator,(spender,approved)));
            require(ok && abi.decode(result,(bool)),"setOperator return");
            require(sameSlot(p,slot)==((dirty&~uint256(255))|(approved?1:0)),"operator reserved bits");
            require(logs.length==1 && logs[0].topics[0]==keccak256("OperatorSet(address,address,bool)"),"operator event");
            (ok,result,)=compare(p,owner,abi.encodeCall(p.sol.isOperator,(owner,spender)));require(ok && abi.decode(result,(bool))==approved,"operator getter");
            (ok,result,logs)=compare(p,owner,abi.encodeCall(p.sol.approve,(spender,id,amount)));require(ok && abi.decode(result,(bool)),"approve return");
            require(sameSlot(p,allowanceSlot(p,owner,spender,id))==amount,"approval storage");
            require(logs.length==1 && logs[0].topics[0]==keccak256("Approval(address,address,uint256,uint256)"),"approval event");
            (ok,result,)=compare(p,owner,abi.encodeCall(p.sol.allowance,(owner,spender,id)));require(ok && abi.decode(result,(uint256))==amount,"allowance getter");
            seed(p,balanceSlot(p,owner,id),amount);
            (ok,result,)=compare(p,owner,abi.encodeCall(p.sol.balanceOf,(owner,id)));require(ok && abi.decode(result,(uint256))==amount,"balance getter");
        }
    }
    function testFuzz_interfaces(bytes4 id) public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];(bool ok,bytes memory out,)=compare(p,address(0),abi.encodeCall(p.sol.supportsInterface,(id)));
            require(ok && abi.decode(out,(bool))==(id==0x01ffc9a7 || id==0x0f632fb3),"ERC165 model");
        }
    }
    function test_boundariesAndIdentity() public {
        testFuzz_interfaces(0x01ffc9a7);testFuzz_interfaces(0x0f632fb3);testFuzz_interfaces(0xffffffff);
        testFuzz_transfer(address(1),address(1),0,type(uint256).max,0,type(uint256).max);
        testFuzz_transfer(address(1),address(2),0,1,type(uint256).max,1);
        testFuzz_transfer(address(0),address(0),type(uint256).max,0,0,0);
        testFuzz_transferFrom(address(1),address(2),address(1),0,type(uint256).max,type(uint256).max,1,false);
        testFuzz_burnFrom(address(1),address(2),0,type(uint256).max,type(uint256).max,1,false);
        testFuzz_burnFrom(address(1),address(1),0,10,0,10,false);
        testFuzz_burnFrom(address(1),address(2),0,10,0,10,true);
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];uint256 id=uint256(1)<<200|17;
            compare(p,address(1),abi.encodeCall(p.sol.mint,(address(1),id,7)));
            require(sameSlot(p,balanceSlot(p,address(1),id))==7 && sameSlot(p,balanceSlot(p,address(1),17))==0,"full 256-bit IDs");
        }
    }
    function testFuzz_lifecycle(uint128 amount) public {
        address owner=address(0x1111);address spender=address(0x2222);address receiver=address(0x3333);uint256 id=0xabcd;
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];
            if(p.root==3)for(uint256 slot;slot<3;slot++) {
                require(sameSlot(p,bytes32(slot))==0,"immutable root occupies no storage");seed(p,bytes32(slot),slot+123);
            }
            (bool ok,,)=compare(p,owner,abi.encodeCall(p.sol.mint,(owner,id,uint256(amount)*3)));require(ok,"mint lifecycle");
            (ok,,)=compare(p,owner,abi.encodeCall(p.sol.approve,(spender,id,amount)));require(ok,"approve lifecycle");
            (ok,,)=compare(p,spender,abi.encodeCall(p.sol.transferFrom,(owner,receiver,id,amount)));require(ok,"allowance transfer");
            require(sameSlot(p,allowanceSlot(p,owner,spender,id))==0,"allowance exhausted");
            (ok,,)=compare(p,owner,abi.encodeCall(p.sol.setOperator,(spender,true)));require(ok,"operator grant");
            (ok,,)=compare(p,spender,abi.encodeCall(p.sol.transferFrom,(owner,receiver,id,amount)));require(ok,"operator transfer");
            (ok,,)=compare(p,owner,abi.encodeCall(p.sol.setOperator,(spender,false)));require(ok,"operator revoke");
            (ok,,)=compare(p,receiver,abi.encodeCall(p.sol.burnFrom,(receiver,id,uint256(amount)*2)));require(ok,"receiver burn");
            (ok,,)=compare(p,owner,abi.encodeCall(p.sol.transfer,(owner,id,amount)));require(ok,"self transfer lifecycle");
            (ok,,)=compare(p,owner,abi.encodeCall(p.sol.burnFrom,(owner,id,amount)));require(ok,"owner burn");
            require(sameSlot(p,balanceSlot(p,owner,id))==0 && sameSlot(p,balanceSlot(p,receiver,id))==0,"lifecycle balances");
            if(p.root==3)for(uint256 slot;slot<3;slot++)require(sameSlot(p,bytes32(slot))==slot+123,"prefix storage preserved");
        }
    }
    function test_staticGetters() public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];seed(p,balanceSlot(p,address(1),7),19);seed(p,allowanceSlot(p,address(1),address(2),7),23);seed(p,operatorSlot(p,address(1),address(2)),1);
            (bool ok,bytes memory out)=p.fe.staticcall(abi.encodeCall(p.sol.balanceOf,(address(1),7)));require(ok && abi.decode(out,(uint256))==19,"static balance");
            (ok,out)=p.fe.staticcall(abi.encodeCall(p.sol.allowance,(address(1),address(2),7)));require(ok && abi.decode(out,(uint256))==23,"static allowance");
            (ok,out)=p.fe.staticcall(abi.encodeCall(p.sol.isOperator,(address(1),address(2))));require(ok && abi.decode(out,(bool)),"static operator");
        }
    }
    function test_allowanceRollbackOnRecipientOverflow() public {
        for(uint256 i;i<2;i++) {
            Deployment memory p=pairs[i];seed(p,balanceSlot(p,address(1),99),10);seed(p,balanceSlot(p,address(3),99),type(uint256).max);seed(p,allowanceSlot(p,address(1),address(2),99),10);
            (bool ok,bytes memory out,Vm.Log[] memory logs)=compare(p,address(2),abi.encodeCall(p.sol.transferFrom,(address(1),address(3),99,1)));
            require(!ok && keccak256(out)==keccak256(abi.encodeWithSignature("Panic(uint256)",0x11)) && logs.length==0,"overflow panic");
            require(sameSlot(p,balanceSlot(p,address(1),99))==10 && sameSlot(p,allowanceSlot(p,address(1),address(2),99))==10,"complete rollback");
        }
    }
}
