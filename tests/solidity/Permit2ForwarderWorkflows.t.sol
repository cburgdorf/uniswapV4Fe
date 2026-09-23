// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Permit2Forwarder} from "./periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "./permit2/src/interfaces/IAllowanceTransfer.sol";
import {PermitHash} from "./permit2/src/libraries/PermitHash.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function addr(uint256) external pure returns(address);
    function sign(uint256,bytes32) external pure returns(uint8,bytes32,bytes32);
    function prank(address) external;
    function warp(uint256) external;
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract WorkflowToken {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function approve(address spender,uint256 amount) external returns(bool){allowance[msg.sender][spender]=amount;return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool){
        if(allowance[from][msg.sender]!=type(uint256).max)allowance[from][msg.sender]-=amount;
        balanceOf[from]-=amount;balanceOf[to]+=amount;return true;
    }
}
contract Permit2ForwarderWorkflowsTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant KEY=123;
    address owner;address fe;Permit2Forwarder sol;IAllowanceTransfer pf;IAllowanceTransfer ps;WorkflowToken tf;WorkflowToken ts;
    function create(bytes memory code) internal returns(address a){assembly {a:=create(0,add(code,32),mload(code))}require(a.code.length>0,"deploy");}
    function setUp() public {
        vm.warp(100);owner=vm.addr(KEY);vm.deal(address(this),100 ether);
        bytes memory code=vm.parseBytes(vm.readFile("permit2-bytecode.txt"));pf=IAllowanceTransfer(create(code));ps=IAllowanceTransfer(create(code));
        fe=create(abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(pf)));sol=new Permit2Forwarder(ps);
        tf=new WorkflowToken();ts=new WorkflowToken();vm.prank(owner);tf.approve(address(pf),type(uint256).max);vm.prank(owner);ts.approve(address(ps),type(uint256).max);
    }
    function sign(IAllowanceTransfer p,bytes32 hash) internal view returns(bytes memory){
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(KEY,keccak256(abi.encodePacked(hex"1901",p.DOMAIN_SEPARATOR(),hash)));
        return abi.encodePacked(r,s,v);
    }
    function allowanceHash(IAllowanceTransfer p,WorkflowToken token) internal view returns(bytes32){
        (uint160 amount,uint48 expiration,uint48 nonce)=p.allowance(owner,address(token),address(this));
        return keccak256(abi.encode(amount,expiration,nonce));
    }
    function run(bytes memory a,bytes memory b,bool succeeds,uint256 events) internal {
        vm.recordLogs();(bool ok,bytes memory out)=fe.call{value:1}(a);Vm.Log[] memory la=vm.getRecordedLogs();
        vm.recordLogs();(bool refOk,bytes memory expected)=address(sol).call{value:1}(b);Vm.Log[] memory lb=vm.getRecordedLogs();
        require(ok&&refOk,"forwarder catches Permit2 failure");require(keccak256(out)==keccak256(expected),"real Permit2 error parity");
        require((abi.decode(out,(bytes)).length==0)==succeeds,"permit outcome");require(la.length==events&&lb.length==events,"permit event count");
        for(uint256 i;i<events;i++){
            require(la[i].emitter==address(pf)&&lb[i].emitter==address(ps),"permit emitter");
            require(keccak256(la[i].data)==keccak256(lb[i].data),"permit values");
            require(la[i].topics.length==4&&lb[i].topics.length==4,"permit topics");
            require(la[i].topics[0]==lb[i].topics[0]&&la[i].topics[1]==lb[i].topics[1]&&la[i].topics[3]==lb[i].topics[3],"permit identity");
            require(la[i].topics[2]==bytes32(uint256(uint160(address(tf))))&&lb[i].topics[2]==bytes32(uint256(uint160(address(ts)))),"permit token");
        }
        require(fe.balance==address(sol).balance,"forwarder retained value");
        require(allowanceHash(pf,tf)==allowanceHash(ps,ts),"allowance parity");
    }
    function testFuzz_singlePermitAndPayment(uint160 amount,bool expired) public {
        uint256 deadline=expired?99:200;
        IAllowanceTransfer.PermitSingle memory a=IAllowanceTransfer.PermitSingle(IAllowanceTransfer.PermitDetails(address(tf),amount,200,0),address(this),deadline);
        IAllowanceTransfer.PermitSingle memory b=IAllowanceTransfer.PermitSingle(IAllowanceTransfer.PermitDetails(address(ts),amount,200,0),address(this),deadline);
        bytes memory ca=abi.encodeCall(sol.permit,(owner,a,sign(pf,PermitHash.hash(a))));bytes memory cb=abi.encodeCall(sol.permit,(owner,b,sign(ps,PermitHash.hash(b))));
        run(ca,cb,!expired,expired?0:1);run(ca,cb,false,0);
        if(!expired){
            tf.mint(owner,amount);ts.mint(owner,amount);uint160 spend=amount/2;address recipient=address(0xb0b);
            pf.transferFrom(owner,recipient,spend,address(tf));ps.transferFrom(owner,recipient,spend,address(ts));
            require(tf.balanceOf(owner)==ts.balanceOf(owner)&&tf.balanceOf(recipient)==spend&&ts.balanceOf(recipient)==spend,"Permit2 token payment");
            (uint160 remaining,,uint48 nonce)=pf.allowance(owner,address(tf),address(this));
            require(remaining==(amount==type(uint160).max?amount:amount-spend)&&nonce==1,"approval consumed");
        }
    }
    function testFuzz_batchNonceSequence(uint8 count) public {
        uint256 n=count%5;
        IAllowanceTransfer.PermitBatch memory a=IAllowanceTransfer.PermitBatch(new IAllowanceTransfer.PermitDetails[](n),address(this),200);
        IAllowanceTransfer.PermitBatch memory b=IAllowanceTransfer.PermitBatch(new IAllowanceTransfer.PermitDetails[](n),address(this),200);
        for(uint256 i;i<n;i++){
            a.details[i]=IAllowanceTransfer.PermitDetails(address(tf),uint160(i+1),200,uint48(i));
            b.details[i]=IAllowanceTransfer.PermitDetails(address(ts),uint160(i+1),200,uint48(i));
        }
        bytes memory ca=abi.encodeCall(sol.permitBatch,(owner,a,sign(pf,PermitHash.hash(a))));bytes memory cb=abi.encodeCall(sol.permitBatch,(owner,b,sign(ps,PermitHash.hash(b))));
        run(ca,cb,true,n);
        // Empty batches consume no nonce and remain replayable in the reference.
        run(ca,cb,n==0,0);
        (uint160 amount,,uint48 nonce)=pf.allowance(owner,address(tf),address(this));require(amount==n&&nonce==n,"batch nonce progression");
    }
}
