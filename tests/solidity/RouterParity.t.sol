// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Router} from "./periphery/src/V4Router.sol";
import {IV4Router} from "./periphery/src/interfaces/IV4Router.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {SwapParams} from "./reference/src/types/PoolOperation.sol";
import {BalanceDelta,toBalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract RouterReference is V4Router {
    constructor(IPoolManager m) V4Router(m) {}
    function msgSender() public view override returns(address) {return msg.sender;}
    function _pay(Currency,address,uint256) internal pure override {revert("payment not used in swap suite");}
    function handle(uint256 action,bytes calldata data) external {_handleAction(action,data);}
}
contract RouterManager {
    bytes32 public trace;uint256 public calls;
    int128 input;int128 output;int256 public credit;bool secondEnabled;int128 secondOutput;
    function configure(int128 i,int128 o,int256 c) external {input=i;output=o;credit=c;trace=0;calls=0;secondEnabled=false;}
    function configureSecond(int128 value) external {secondEnabled=true;secondOutput=value;}
    function reset() external {trace=0;calls=0;}
    function exttload(bytes32) external view returns(bytes32) {return bytes32(uint256(credit));}
    function swap(PoolKey calldata,SwapParams calldata p,bytes calldata) external returns(BalanceDelta) {
        trace=keccak256(abi.encode(trace,msg.data));calls++;
        int128 received=secondEnabled && calls==2?secondOutput:output;
        return p.zeroForOne?toBalanceDelta(input,received):toBalanceDelta(received,input);
    }
}
contract RouterParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;RouterReference sol;RouterManager manager;
    function setUp() public {
        manager=new RouterManager();
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(manager),address(0)));
        address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"deploy");fe=f;
        sol=new RouterReference(IPoolManager(address(manager)));
    }
    function key() internal pure returns(PoolKey memory) {return PoolKey(Currency.wrap(address(10)),Currency.wrap(address(20)),3000,60,IHooks(address(0)));}
    function compare(uint256 action,bytes memory data) internal returns(bool ok,bytes memory out) {
        bytes memory args=abi.encodeCall(sol.handle,(action,data));manager.reset();
        (ok,out)=fe.call{gas:2000000}(args);bytes32 trace=manager.trace();uint256 calls=manager.calls();manager.reset();
        (bool other,bytes memory expected)=address(sol).call{gas:2000000}(args);
        require(ok==other,"router status mismatch");require(keccak256(out)==keccak256(expected),"router revert mismatch");
        require(trace==manager.trace() && calls==manager.calls(),"router swap calls mismatch");
    }
    function testFuzz_single(int128 input,int128 output,uint128 amount,uint128 bound,uint256 price,bool exactOut,bool direction,bytes memory hook) public {
        manager.configure(input,output,17);
        bytes memory data=abi.encode(IV4Router.ExactInputSingleParams(key(),direction,amount,bound,price,hook));
        compare(exactOut?8:6,data);
    }
    function testFuzz_multi(int128 input,int128 output,uint128 amount,uint128 bound,uint256 price,bool exactOut,uint8 count) public {
        manager.configure(input,output,17);uint256 n=count%4;
        PathKey[] memory paths=new PathKey[](n);
        for(uint256 i;i<n;i++) paths[i]=PathKey(Currency.wrap(address(uint160(20+i*10))),3000,60,IHooks(address(0)),abi.encode(i));
        uint256[] memory prices=new uint256[](price%3==0?0:price%3==1?n:n+1);
        for(uint256 i;i<prices.length;i++)prices[i]=price;
        compare(exactOut?9:7,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),paths,prices,amount,bound)));
    }
    function testFuzz_raw(bytes memory data,uint8 action) public {
        manager.configure(-7,11,17);compare(6+action%4,data);
    }
    function testFuzz_mutatedSingle(uint256 dirty,uint8 index) public {
        manager.configure(-7,11,17);
        bytes memory data=abi.encode(IV4Router.ExactInputSingleParams(key(),true,7,0,0,hex"1122"));
        uint256 i=index%12;assembly {mstore(add(add(data,32),mul(i,32)),dirty)}
        compare(6,data);compare(8,data);
    }
    function test_successAndUnfilled() public {
        manager.configure(-7,11,17);
        (bool ok,)=compare(6,abi.encode(IV4Router.ExactInputSingleParams(key(),true,7,11,0,"")));require(ok,"exact input success");
        (ok,)=compare(8,abi.encode(IV4Router.ExactOutputSingleParams(key(),false,11,7,0,"")));require(ok,"exact output success");
        bytes memory reason; (ok,reason)=compare(8,abi.encode(IV4Router.ExactOutputSingleParams(key(),true,12,7,0,"")));
        require(!ok && keccak256(reason)==keccak256(abi.encodeWithSelector(IV4Router.V4ExactOutputUnfilled.selector,uint256(12),uint256(11))),"unfilled");
        PathKey[] memory path=new PathKey[](2);path[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),"");path[1]=PathKey(Currency.wrap(address(30)),3000,60,IHooks(address(0)),"");
        (ok,)=compare(7,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),path,new uint256[](0),7,11)));require(ok && manager.calls()==2,"two hops input");
        (ok,)=compare(9,abi.encode(IV4Router.ExactOutputParams(Currency.wrap(address(10)),path,new uint256[](0),11,7)));require(ok && manager.calls()==2,"two hops output");
    }
    function test_secondHopMustFillAndPriceLimit() public {
        manager.configure(-7,11,17);manager.configureSecond(5);
        PathKey[] memory path=new PathKey[](2);
        path[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),"");
        path[1]=PathKey(Currency.wrap(address(30)),3000,60,IHooks(address(0)),"");
        (bool ok,bytes memory reason)=compare(9,abi.encode(IV4Router.ExactOutputParams(Currency.wrap(address(10)),path,new uint256[](0),11,100)));
        require(!ok && keccak256(reason)==keccak256(abi.encodeWithSelector(IV4Router.V4ExactOutputUnfilled.selector,uint256(7),uint256(5))),"second hop unfilled");
        manager.configure(-7,11,17);
        uint256[] memory prices=new uint256[](2);prices[1]=11e35;
        (ok,reason)=compare(7,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),path,prices,7,0)));
        require(!ok && keccak256(reason)==keccak256(abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHop.selector,uint256(1),uint256(11e35),uint256(1e36))),"second hop price");
    }
    function expectError(uint256 action,bytes memory data,bytes memory expected) internal {
        (bool ok,bytes memory reason)=compare(action,data);
        require(!ok&&keccak256(reason)==keccak256(expected),"explicit interface error");
    }
    function test_interfaceErrorMatrix() public {
        manager.configure(-7,11,17);
        uint256 price=uint256(11e36)/7;
        expectError(6,abi.encode(IV4Router.ExactInputSingleParams(key(),true,7,12,0,"")),abi.encodeWithSelector(IV4Router.V4TooLittleReceived.selector,uint256(12),uint256(11)));
        expectError(8,abi.encode(IV4Router.ExactOutputSingleParams(key(),true,11,6,0,"")),abi.encodeWithSelector(IV4Router.V4TooMuchRequested.selector,uint256(6),uint256(7)));
        expectError(6,abi.encode(IV4Router.ExactInputSingleParams(key(),true,7,0,2e36,"")),abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHopSingle.selector,uint256(2e36),price));
        expectError(8,abi.encode(IV4Router.ExactOutputSingleParams(key(),true,11,7,2e36,"")),abi.encodeWithSelector(IV4Router.V4TooMuchRequestedPerHopSingle.selector,uint256(2e36),price));
        expectError(8,abi.encode(IV4Router.ExactOutputSingleParams(key(),true,12,7,0,"")),abi.encodeWithSelector(IV4Router.V4ExactOutputUnfilled.selector,uint256(12),uint256(11)));
        PathKey[] memory path=new PathKey[](1);path[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),"");
        uint256[] memory prices=new uint256[](1);prices[0]=2e36;
        expectError(7,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),path,prices,7,0)),abi.encodeWithSelector(IV4Router.V4TooLittleReceivedPerHop.selector,uint256(0),uint256(2e36),price));
        expectError(9,abi.encode(IV4Router.ExactOutputParams(Currency.wrap(address(10)),path,prices,11,7)),abi.encodeWithSelector(IV4Router.V4TooMuchRequestedPerHop.selector,uint256(0),uint256(2e36),price));
        expectError(7,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),path,new uint256[](2),7,0)),abi.encodeWithSelector(IV4Router.InvalidHopPriceLength.selector));
    }
    function test_shortParametersAndUnsupportedActions() public {
        manager.configure(-7,11,17);
        for(uint256 len;len<385;len++) for(uint256 action=6;action<10;action++) compare(action,new bytes(len));
        (bool ok,bytes memory reason)=compare(26,"");
        require(!ok && keccak256(reason)==keccak256(abi.encodeWithSignature("UnsupportedAction(uint256)",uint256(26))),"unsupported");
    }

    function test_signedHookOffset() public {
        manager.configure(-7,11,17);
        bytes memory data=abi.encode(IV4Router.ExactInputSingleParams(key(),true,7,0,0,hex"1122"));
        assembly {mstore(add(data,352),0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23)}
        (bool ok,)=compare(6,data);require(ok,"negative offset accepted as empty hook data");
    }

    function testFuzz_mutatedMulti(uint256 dirty,uint8 index) public {
        manager.configure(-7,11,17);
        PathKey[] memory path=new PathKey[](1);
        path[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),hex"1122");
        bytes memory data=abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(10)),path,new uint256[](0),7,0));
        uint256 i=uint256(index)%(data.length/32);
        assembly {mstore(add(add(data,32),mul(i,32)),dirty)}
        compare(7,data);compare(9,data);
    }

}
