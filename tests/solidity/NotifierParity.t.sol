// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Notifier} from "./periphery/src/base/Notifier.sol";
import {PositionInfo} from "./periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {ISubscriber} from "./periphery/src/interfaces/ISubscriber.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function etch(address,bytes calldata) external;
    function load(address,bytes32) external view returns(bytes32);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract SolidityNotifier is Notifier {
    mapping(uint256=>uint256) public info;
    constructor(uint256 limit) Notifier(limit) {}
    modifier onlyIfApproved(address,uint256) override {_ ;}
    modifier onlyIfPoolManagerLocked() override {_ ;}
    function _setSubscribed(uint256 id) internal override {info[id]|=1;}
    function _setUnsubscribed(uint256 id) internal override {info[id]&=~uint256(255);}
    function seed(uint256 id,uint256 value) external {info[id]=value;}
    function burn(uint256 id,address owner,uint256 i,uint256 liq,int256 fees) external {_removeSubscriberAndNotifyBurn(id,owner,PositionInfo.wrap(i),liq,BalanceDelta.wrap(fees));}
    function modify(uint256 id,int256 delta,int256 fees) external {_notifyModifyLiquidity(id,delta,BalanceDelta.wrap(fees));}
}
interface INotifierProbe {
    function subscriber(uint256) external view returns(address);
    function info(uint256) external view returns(uint256);
    function unsubscribe(uint256) external payable;
}
contract SubscriberProbe {
    uint256 mode;bytes reason;
    bytes public args;
    function configure(uint256 m,bytes memory r) external {mode=m;reason=r;}
    fallback() external {
        uint256 id=abi.decode(msg.data[4:36],(uint256));bytes4 selector=msg.sig;
        address current=INotifierProbe(msg.sender).subscriber(id);
        if(selector==ISubscriber.notifySubscribe.selector){
            require(current==address(this),"subscribed before callback");require(INotifierProbe(msg.sender).info(id)&1==1,"flag before callback");
        }
        if(selector==ISubscriber.notifyUnsubscribe.selector){
            require(current==address(0),"cleared before callback");require(INotifierProbe(msg.sender).info(id)&255==0,"flag cleared before callback");
        }
        if(selector==ISubscriber.notifyBurn.selector)require(current==address(0),"cleared before burn");
        args=msg.data;
        if(mode==1||(mode==2&&selector==ISubscriber.notifyUnsubscribe.selector)){bytes memory r=reason;assembly {revert(add(r,32),mload(r))}}
        if(mode==3&&selector==ISubscriber.notifySubscribe.selector)INotifierProbe(msg.sender).unsubscribe(id);
    }
}
contract NotifierParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityNotifier sol;SubscriberProbe provider;
    function deploy(uint256 limit) internal {
        bytes memory code=abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(limit));address f;
        assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;sol=new SolidityNotifier(limit);
    }
    function setUp() public {provider=new SubscriberProbe();deploy(500000);vm.deal(address(this),100 ether);}
    function argsHash() internal view returns(bytes32){return address(provider).code.length==0?bytes32(0):keccak256(provider.args());}
    function compare(bytes memory data,uint256 value,uint256 id) internal returns(bool ok,bytes memory out){
        vm.recordLogs();(ok,out)=fe.call{gas:5000000,value:value}(data);Vm.Log[] memory a=vm.getRecordedLogs();bytes32 args=argsHash();
        vm.recordLogs();(bool refOk,bytes memory expected)=address(sol).call{gas:5000000,value:value}(data);Vm.Log[] memory b=vm.getRecordedLogs();
        require(ok==refOk,"notifier status");require(keccak256(out)==keccak256(expected),"notifier result");require(args==argsHash(),"callback args");
        require(a.length==b.length,"logs length");for(uint256 i;i<a.length;i++){require(a[i].emitter==fe&&b[i].emitter==address(sol),"emitter");require(keccak256(abi.encode(a[i].topics,a[i].data))==keccak256(abi.encode(b[i].topics,b[i].data)),"logs");}
        for(uint256 i;i<2;i++){bytes32 slot=keccak256(abi.encode(id,i));require(vm.load(fe,slot)==vm.load(address(sol),slot),"storage");}
        require(fe.balance==address(sol).balance,"value rollback");
    }
    function testFuzz_subscription(uint256 id,uint256 info,bytes memory data,uint8 mode,uint64 value) public {
        compare(abi.encodeCall(sol.seed,(id,info)),0,id);provider.configure(mode%4,data);
        compare(abi.encodeCall(sol.subscribe,(id,address(provider),data)),uint256(value)%1 ether,id);
        compare(abi.encodeCall(sol.subscribe,(id,address(provider),data)),0,id);
        compare(abi.encodeCall(sol.unsubscribe,(id)),1,id);
        compare(abi.encodeCall(sol.unsubscribe,(id)),0,id);
    }
    function testFuzz_notifications(uint256 id,address owner,uint256 info,uint256 liquidity,int256 fees,bytes memory reason,bool reject) public {
        compare(abi.encodeCall(sol.subscribe,(id,address(provider),bytes("hello"))),0,id);
        provider.configure(reject?1:0,reason);
        compare(abi.encodeCall(sol.modify,(id,int256(liquidity),fees)),0,id);
        compare(abi.encodeCall(sol.burn,(id,owner,info,liquidity,fees)),0,id);
        compare(abi.encodeCall(sol.modify,(id,int256(0),fees)),0,id);
    }
    function test_noCodeAndGasLimit() public {
        (bool ok,)=compare(abi.encodeCall(sol.subscribe,(1,address(0),bytes(""))),1,1);require(!ok);
        (ok,)=compare(abi.encodeCall(sol.subscribe,(1,address(123),bytes(""))),1,1);require(!ok);
        deploy(1000000000);(ok,)=compare(abi.encodeCall(sol.subscribe,(1,address(provider),bytes(""))),0,1);require(ok);
        (ok,)=compare(abi.encodeCall(sol.unsubscribe,(1)),1,1);require(!ok,"insufficient notification budget");
        deploy(1000);(ok,)=compare(abi.encodeCall(sol.subscribe,(1,address(provider),bytes(""))),0,1);require(ok);
        (ok,)=compare(abi.encodeCall(sol.unsubscribe,(1)),1,1);require(ok,"callee OOG swallowed");
    }
    function test_removedSubscriberCode() public {
        (bool ok,)=compare(abi.encodeCall(sol.subscribe,(1,address(provider),bytes(""))),0,1);require(ok);
        vm.etch(address(provider),bytes(""));
        (ok,)=compare(abi.encodeCall(sol.unsubscribe,(1)),1,1);require(ok,"no callback after code removal");
    }

}
