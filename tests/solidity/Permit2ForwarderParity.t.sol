// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Permit2Forwarder} from "./periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "./permit2/src/interfaces/IAllowanceTransfer.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
}
contract PermitTarget {
    uint256 mode;bytes reason;
    bytes public args;
    function configure(uint256 m,bytes memory r) external {mode=m;reason=r;}
    fallback() external {
        args=msg.data;
        if(mode==1){bytes memory r=reason;assembly {revert(add(r,32),mload(r))}}
        if(mode==2)assembly {return(0,10000)}
    }
}
contract Permit2ForwarderParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;Permit2Forwarder sol;PermitTarget target;
    function deploy(address p) internal {
        bytes memory code=abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(p));address f;
        assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;sol=new Permit2Forwarder(IAllowanceTransfer(p));
    }
    function setUp() public {target=new PermitTarget();deploy(address(target));vm.deal(address(this),100 ether);}
    function compare(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out){
        (ok,out)=fe.call{value:value}(data);bytes32 args=keccak256(target.args());
        (bool refOk,bytes memory expected)=address(sol).call{value:value}(data);
        require(ok==refOk,"forwarder status");require(keccak256(out)==keccak256(expected),"forwarder result");require(args==keccak256(target.args()),"forwarded args");
        require(fe.balance==address(sol).balance,"value rollback");require(address(target).balance==0,"value not forwarded");
    }
    function testFuzz_single(address owner,address token,uint160 amount,uint48 expiration,uint48 nonce,address spender,uint256 deadline,bytes memory sig,bytes memory reason,uint8 mode) public {
        IAllowanceTransfer.PermitSingle memory p=IAllowanceTransfer.PermitSingle(IAllowanceTransfer.PermitDetails(token,amount,expiration,nonce),spender,deadline);
        target.configure(mode%3,reason);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.permit,(owner,p,sig)),1);require(ok,"target revert must be caught");
        require(keccak256(abi.decode(out,(bytes)))==keccak256(mode%3==1?reason:bytes("")),"error payload");
        if(mode%3!=1)require(keccak256(target.args())==keccak256(abi.encodeWithSignature("permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)",owner,p,sig)),"single target calldata");
    }
    function batch(uint256 seed,uint8 count,address spender) internal pure returns(IAllowanceTransfer.PermitBatch memory p){
        p.details=new IAllowanceTransfer.PermitDetails[](count%9);p.spender=spender;p.sigDeadline=seed;
        for(uint256 i;i<p.details.length;i++){uint256 h=uint256(keccak256(abi.encode(seed,i)));p.details[i]=IAllowanceTransfer.PermitDetails(address(uint160(h)),uint160(h>>32),uint48(h>>192),uint48(h>>208));}
    }
    function testFuzz_batch(uint256 seed,uint8 count,address spender,bytes memory sig,bytes memory reason,uint8 mode) public {
        IAllowanceTransfer.PermitBatch memory p=batch(seed,count,spender);target.configure(mode%3,reason);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.permitBatch,(address(123),p,sig)),1);require(ok);
        require(keccak256(abi.decode(out,(bytes)))==keccak256(mode%3==1?reason:bytes("")),"batch error");
        if(mode%3!=1)require(keccak256(target.args())==keccak256(abi.encodeWithSignature("permit(address,((address,uint160,uint48,uint48)[],address,uint256),bytes)",address(123),p,sig)),"batch target calldata");
    }
    function test_dirtyArrayElementAndNoCode() public {
        IAllowanceTransfer.PermitBatch memory p=batch(123,1,address(456));bytes memory data=abi.encodeCall(sol.permitBatch,(address(123),p,bytes("sig")));
        assembly {
            let base:=add(4,mload(add(data,68)))
            let arr:=add(base,mload(add(add(data,32),base)))
            mstore(add(add(data,32),add(arr,64)),shl(160,1))
        }
        (bool ok,)=compare(data,1);require(!ok,"dirty array amount");require(target.args().length==0);
        deploy(address(789));data=abi.encodeCall(sol.permitBatch,(address(123),p,bytes("sig")));
        (ok,)=compare(data,1);require(!ok,"no-code check outside catch");
    }
    function encodedPermit(bool isBatch) internal view returns(bytes memory) {
        if(isBatch)return abi.encodeCall(sol.permitBatch,(address(123),batch(123,2,address(456)),bytes("signature")));
        IAllowanceTransfer.PermitSingle memory p=IAllowanceTransfer.PermitSingle(IAllowanceTransfer.PermitDetails(address(789),123,456,7),address(456),789);
        return abi.encodeCall(sol.permit,(address(123),p,bytes("signature")));
    }
    function testFuzz_mutatedCalldata(uint256 seed,uint256 word,bool isBatch,bool truncate) public {
        bytes memory data=encodedPermit(isBatch);
        if(truncate) {
            uint256 length=seed%(data.length+1);assembly {mstore(data,length)}
        } else {
            uint256 offset=4+32*(seed%((data.length-4)/32));
            assembly {mstore(add(add(data,32),offset),word)}
        }
        compare(data,1);
    }
    function test_everyTruncatedPrefix() public {
        for(uint256 mode;mode<2;mode++) {
            bytes memory data=encodedPermit(mode==1);uint256 full=data.length;
            for(uint256 length;length<full;length++) {
                assembly {mstore(data,length)}
                compare(data,1);
            }
        }
    }

    function test_batchOverflowingDetailsOffset() public {testFuzz_mutatedCalldata(94960564125535,type(uint256).max,true,false);}

    function test_batchOverflowingSignatureOffset() public {testFuzz_mutatedCalldata(131072,type(uint256).max-31,true,false);}

}
