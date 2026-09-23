// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {DeltaResolver} from "./periphery/src/base/DeltaResolver.sol";
import {ImmutableState} from "./periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {Currency} from "./reference/src/types/Currency.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
}
interface IPayment {function transferFrom(address,address,uint160,address) external;}
contract PaymentsReference is DeltaResolver {
    IPayment immutable permit2;
    constructor(IPoolManager manager,IPayment permit_) ImmutableState(manager) {permit2=permit_;}
    function _pay(Currency currency,address payer,uint256 amount) internal override {
        // Payment hook from the pinned PositionManager._pay.
        if(payer==address(this)) currency.transfer(address(poolManager),amount);
        else permit2.transferFrom(payer,address(poolManager),uint160(amount),Currency.unwrap(currency));
    }
    function perform(Currency currency,address payer,address recipient,uint256 amount,bool isTake) external {
        if(isTake) _take(currency,recipient,amount);
        else _settle(currency,payer==address(1)?address(this):payer,amount);
    }
}
contract PaymentTrace {
    uint256 public stage;
    address public currency;address public recipient;address public payer;
    uint256 public amount;uint256 public paid;uint256 public nativeValue;
    uint8 public failAt;uint8 public returnMode;
    function reset(uint8 fail,uint8 ret) external {stage=0;currency=address(0);recipient=address(0);payer=address(0);amount=0;paid=0;nativeValue=0;failAt=fail;returnMode=ret;}
    function sync(address c) external {require(stage==0,"sync order");if(failAt==1) revert("sync failure");currency=c;stage=1;}
    function payment(address from,address to,address token,uint256 value) external {
        require(stage==1 && currency==token && to==address(this),"payment order");
        if(failAt==2) revert("payment failure");payer=from;paid=value;stage=2;
    }
    function settle() external payable returns(uint256) {
        require((currency==address(0) && stage==1)||(currency!=address(0) && stage==2),"settle order");
        if(failAt==3) revert("settle failure");nativeValue=msg.value;stage=3;
        uint8 r=returnMode;assembly {if eq(r,1) {return(0,0)} if eq(r,2) {mstore(0,1) return(0,31)}}
        return msg.value+paid;
    }
    function take(address c,address to,uint256 value) external {
        require(stage==0,"take order");if(failAt==4) revert("take failure");currency=c;recipient=to;amount=value;stage=4;
    }
}
contract PaymentToken {
    PaymentTrace immutable trace;
    constructor(PaymentTrace t) {trace=t;}
    function transfer(address to,uint256 amount) external returns(bool) {trace.payment(msg.sender,to,address(this),amount);return true;}
}
contract Permit2Trace {
    PaymentTrace immutable trace;
    constructor(PaymentTrace t) {trace=t;}
    function transferFrom(address from,address to,uint160 amount,address token) external {trace.payment(from,to,token,amount);}
}
contract PaymentsParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;PaymentsReference sol;PaymentTrace manager;PaymentToken token;Permit2Trace permit2;
    function deploy(address m,address p) internal returns(address f,PaymentsReference s) {
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(m,p));
        assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");
        s=new PaymentsReference(IPoolManager(m),IPayment(p));
    }
    function setUp() public {
        manager=new PaymentTrace();token=new PaymentToken(manager);permit2=new Permit2Trace(manager);
        (fe,sol)=deploy(address(manager),address(permit2));
    }
    function stateHash(address implementation) internal view returns(bytes32) {
        address p=manager.payer();if(p==implementation)p=address(1);
        return keccak256(abi.encode(manager.stage(),manager.currency(),manager.recipient(),p,manager.amount(),manager.paid(),manager.nativeValue()));
    }
    function compare(bytes memory data,uint256 balance,uint8 fail,uint8 ret) internal returns(bool ok,bytes memory out) {
        manager.reset(fail,ret);vm.deal(fe,balance);vm.deal(address(sol),balance);vm.deal(address(manager),0);
        (ok,out)=fe.call(data);bytes32 actual=stateHash(fe);uint256 left=fe.balance;uint256 gained=address(manager).balance;
        manager.reset(fail,ret);vm.deal(address(manager),0);
        (bool other,bytes memory expected)=address(sol).call(data);
        require(ok==other,"payment status mismatch");require(keccak256(out)==keccak256(expected),"payment return mismatch");
        require(actual==stateHash(address(sol)),"payment state/order mismatch");
        require(left==address(sol).balance && gained==address(manager).balance,"payment native balances");
    }
    function testFuzz_settle(uint256 amount,bool native,bool self,uint8 fail,uint8 ret) public {
        Currency c=Currency.wrap(native?address(0):address(token));
        compare(abi.encodeCall(sol.perform,(c,self?address(1):address(123),address(0),amount,false)),native?amount:0,fail%5,ret%3);
    }
    function testFuzz_take(uint256 amount,address recipient,uint8 fail) public {
        compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),recipient,amount,true)),0,fail%5,0);
    }
    function test_zeroAndCodeChecks() public {
        (bool ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),uint256(0),false)),0,1,0);
        require(ok && manager.stage()==0,"zero settle");
        (ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),uint256(0),true)),0,4,0);
        require(ok && manager.stage()==0,"zero take");
        (fe,sol)=deploy(address(0x123456),address(permit2));
        (ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),uint256(1),true)),0,0,0);require(!ok,"take requires manager code");
        (ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),uint256(1),false)),0,0,0);require(!ok,"sync requires manager code");
        (fe,sol)=deploy(address(manager),address(0x123456));
        (ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),uint256(1),false)),0,0,0);require(!ok,"permit2 requires code");
    }
    function test_nativeInsufficientAndPermitTruncation() public {
        (bool ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(0)),address(123),address(0),uint256(2),false)),1,0,0);require(!ok,"insufficient native");
        (ok,)=compare(abi.encodeCall(sol.perform,(Currency.wrap(address(token)),address(123),address(0),(uint256(1)<<160)+7,false)),0,0,0);
        require(ok && manager.paid()==7,"uint160 truncation");
    }
}
