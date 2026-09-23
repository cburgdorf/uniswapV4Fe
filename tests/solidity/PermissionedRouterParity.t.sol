// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PermissionedV4Router} from "./periphery/src/hooks/permissionedPools/PermissionedV4Router.sol";
import {IPermissionsAdapter} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IPermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {SwapParams} from "./reference/src/types/PoolOperation.sol";
import {BalanceDelta,toBalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {IV4Router} from "./periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function etch(address,bytes calldata) external;
    function deal(address,uint256) external;
    function prank(address) external;
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract RouterAsset {
    mapping(address=>uint256) public balanceOf;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address who,uint256 amount) external {balanceOf[who]+=amount;}
    function transfer(address to,uint256 amount) external returns(bool) {move(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool) {move(from,to,amount);return true;}
    function move(address from,address to,uint256 amount) internal {balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
}
contract RouterPermission is RouterAsset {
    bool enabled;bool allowed;bool hookAllowed;uint8 shape;bool fails;
    address public expectedSender;address public expectedHook;
    uint256 public wrapped;
    event Wrapped(address sender,uint256 amount);
    function configure(bool e,bool a,bool h,uint8 s,bool f,address sender,address hook) external {enabled=e;allowed=a;hookAllowed=h;shape=s;fails=f;expectedSender=sender;expectedHook=hook;}
    function wrapToPoolManager(uint256 amount) external {wrapped+=amount;emit Wrapped(msg.sender,amount);}
    fallback(bytes calldata data) external returns(bytes memory) {
        if(fails)revert("permission read");
        bool value;
        if(bytes4(data)==bytes4(keccak256("swappingEnabled()")))value=enabled;
        else if(bytes4(data)==bytes4(keccak256("isAllowed(address,bytes2)"))) {
            (address sender,bytes2 flag)=abi.decode(data[4:],(address,bytes2));
            require(sender==expectedSender&&flag==bytes2(0x0001),"permission args");value=allowed;
        } else if(bytes4(data)==bytes4(keccak256("allowedHooks(address)"))) {
            require(abi.decode(data[4:],(address))==expectedHook,"hook arg");value=hookAllowed;
        } else revert("permission selector");
        if(shape==1)return hex"01";
        if(shape==2)return abi.encode(uint256(2));
        if(shape==3)return bytes.concat(abi.encode(value),hex"ff");
        return abi.encode(value);
    }
}
contract RouterRegistry {
    mapping(address=>address) tokens;
    uint8 shape;bool fails;
    function register(address adapter,address underlying) external {tokens[adapter]=underlying;}
    function configure(uint8 s,bool f) external {shape=s;fails=f;}
    fallback(bytes calldata data) external returns(bytes memory) {
        require(bytes4(data)==bytes4(keccak256("verifiedPermissionsAdapterOf(address)")),"registry selector");
        if(fails)revert("registry read");
        address result=tokens[abi.decode(data[4:],(address))];
        if(shape==1)return hex"01";
        if(shape==2)return abi.encode(type(uint256).max);
        if(shape==3)return bytes.concat(abi.encode(result),hex"ff");
        return abi.encode(result);
    }
}
// Transport test double: full Permit2 integration is a separate workflow suite.
contract RouterPermit {
    bytes32 public trace;
    function transferFrom(address from,address to,uint160 amount,address token) external {
        trace=keccak256(abi.encode(trace,msg.sender,msg.data));RouterAsset(token).transferFrom(from,to,amount);
    }
}
contract PermissionedManager {
    bytes32 public trace;uint256 public calls;int256 public delta;
    int128 input=-7;int128 output=11;
    function configure(int256 d,int128 i,int128 o) external {delta=d;input=i;output=o;}
    function record() internal {trace=keccak256(abi.encode(trace,msg.sender,msg.data,msg.value));calls++;}
    function exttload(bytes32) external view returns(bytes32) {return bytes32(uint256(delta));}
    function sync(address) external {record();}
    function settle() external payable returns(uint256) {record();return 1;}
    function take(address,address,uint256) external {record();}
    function swap(PoolKey calldata,SwapParams calldata p,bytes calldata) external returns(BalanceDelta) {
        record();return p.zeroForOne?toBalanceDelta(input,output):toBalanceDelta(output,input);
    }
    receive() external payable {}
}
contract PermissionedReference is PermissionedV4Router {
    RouterPermit immutable permit2;
    constructor(IPoolManager m,RouterPermit p,IPermissionsAdapterFactory f) PermissionedV4Router(m,f) {permit2=p;}
    function msgSender() public view override returns(address) {return msg.sender;}
    function _payStandard(Currency c,address payer,uint256 amount) internal override {
        if(payer==address(this))c.transfer(address(poolManager),amount);
        else permit2.transferFrom(payer,address(poolManager),uint160(amount),Currency.unwrap(c));
    }
    function _payPermissionedFromPayer(address payer,IPermissionsAdapter adapter,address token,uint256 amount) internal override {
        permit2.transferFrom(payer,address(adapter),uint160(amount),token);adapter.wrapToPoolManager(amount);
    }
    function handle(uint256 a,bytes calldata data) external {_handleAction(a,data);}
    function pay(Currency c,address payer,uint256 amount) external {_pay(c,payer,amount);}
    function take(Currency c,address recipient,uint256 amount) external {_take(c,recipient,amount);}
    function mapSettle(uint256 amount,Currency c) external view returns(uint256) {return _mapSettleAmount(amount,c);}
    function validate(PoolKey memory k) external view {_validatePoolKey(k);}
}
contract PermissionedRouterParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant TARGET=address(0xBee123);address constant USER=address(0xA11CE);address constant HOOK=address(0x123456);
    RouterAsset asset;RouterPermission adapter;RouterPermission other;RouterRegistry registry;RouterPermit permit2;PermissionedManager manager;
    bytes feCode;bytes solCode;bytes creation;
    function deploy(bytes memory code) internal returns(address a) {assembly ("memory-safe") {a:=create(0,add(code,32),mload(code))}require(a.code.length>0);}
    function configureFactory(address factory) internal {
        feCode=deploy(bytes.concat(creation,abi.encode(address(manager),address(permit2),factory))).code;
        solCode=address(new PermissionedReference(IPoolManager(address(manager)),permit2,IPermissionsAdapterFactory(factory))).code;
        vm.etch(TARGET,solCode);
    }
    function setUp() public {
        asset=new RouterAsset();adapter=new RouterPermission();other=new RouterPermission();registry=new RouterRegistry();permit2=new RouterPermit();manager=new PermissionedManager();
        creation=vm.parseBytes(vm.readFile("fe-bytecode.txt"));configureFactory(address(registry));
        registry.register(address(adapter),address(asset));registry.register(address(other),address(asset));
        adapter.configure(true,true,true,0,false,USER,HOOK);other.configure(true,true,true,0,false,USER,HOOK);
        asset.mint(USER,1e30);asset.mint(TARGET,1e30);adapter.mint(USER,1e30);adapter.mint(TARGET,1e30);
        vm.deal(TARGET,1e30);vm.deal(address(this),100);
        manager.configure(-7,-7,11);
    }
    function key() internal view returns(PoolKey memory) {
        return PoolKey(Currency.wrap(address(adapter)),Currency.wrap(address(other)),3000,60,IHooks(HOOK));
    }
    function invoke(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out,bytes32 digest) {
        vm.recordLogs();vm.prank(USER);(ok,out)=TARGET.call{gas:5_000_000,value:value}(data);
        digest=keccak256(abi.encode(vm.getRecordedLogs(),manager.trace(),manager.calls(),permit2.trace(),adapter.wrapped(),other.wrapped(),TARGET.balance,address(manager).balance));
        address[4] memory owners=[USER,TARGET,address(adapter),address(manager)];
        for(uint256 i;i<owners.length;++i)digest=keccak256(abi.encode(digest,asset.balanceOf(owners[i]),adapter.balanceOf(owners[i])));
    }
    function compare(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out) {
        uint256 snap=vm.snapshotState();vm.etch(TARGET,feCode);
        (bool a,bytes memory x,bytes32 left)=invoke(data,value);
        require(vm.revertToState(snap));vm.etch(TARGET,solCode);
        bytes32 right;(ok,out,right)=invoke(data,value);
        require(a==ok,"status");require(keccak256(x)==keccak256(out),"return/revert");require(left==right,"calls/state/events/rollback");
    }
    function testFuzz_pay(uint128 amount,bool self,bool verified,bool enabled,bool allowed) public {
        registry.register(address(adapter),verified?address(asset):address(0));adapter.configure(enabled,allowed,true,0,false,USER,HOOK);
        compare(abi.encodeWithSignature("pay(address,address,uint256)",address(adapter),self?TARGET:USER,uint256(amount)),0);
    }
    function testFuzz_take(uint256 amount,bool verified,bool enabled,bool allowed) public {
        registry.register(address(adapter),verified?address(asset):address(0));adapter.configure(enabled,allowed,true,0,false,USER,HOOK);
        compare(abi.encodeWithSignature("take(address,address,uint256)",address(adapter),USER,amount),0);
    }
    function testFuzz_mapping(uint256 amount,int256 delta,bool verified,uint8 mode) public {
        registry.register(address(adapter),verified?address(asset):address(0));manager.configure(delta,-7,11);
        uint256 mapped=mode%3==0?uint256(1)<<255:mode%3==1?0:amount;
        compare(abi.encodeWithSignature("mapSettle(uint256,address)",mapped,address(adapter)),0);
    }
    function testFuzz_permissions(bool leftVerified,bool rightVerified,bool leftAllowed,bool rightAllowed,uint8 shape,bool fails) public {
        registry.register(address(adapter),leftVerified?address(asset):address(0));registry.register(address(other),rightVerified?address(asset):address(0));
        adapter.configure(true,true,leftAllowed,shape%4,fails,USER,HOOK);other.configure(true,true,rightAllowed,0,false,USER,HOOK);
        compare(abi.encodeWithSignature("validate((address,address,uint24,int24,address))",key()),0);
    }
    function testFuzz_single(uint128 amount,uint128 bound,bool exactOut,bool direction,bool approved) public {
        adapter.configure(true,true,approved,0,false,USER,HOOK);
        compare(abi.encodeWithSignature("handle(uint256,bytes)",exactOut?8:6,abi.encode(IV4Router.ExactInputSingleParams(key(),direction,amount,bound,0,""))),0);
    }
    function testFuzz_actions(uint128 amount,uint8 mode,bool approved,bool self) public {
        adapter.configure(approved,approved,true,0,false,USER,HOOK);
        uint256 action=11+mode%6;bytes memory params;
        uint256 value=mode%3==0?0:mode%3==1?uint256(1)<<255:amount;
        if(action==11)params=abi.encode(address(adapter),value,!self);
        else if(action==12||action==15)params=abi.encode(address(adapter),uint256(amount));
        else params=abi.encode(address(adapter),USER,value);
        compare(abi.encodeWithSignature("handle(uint256,bytes)",action,params),0);
    }
    function testFuzz_raw(bytes memory data,uint8 action) public {
        compare(abi.encodeWithSignature("handle(uint256,bytes)",uint256(action)%18,data),0);
    }
    function test_zeroAmountsAndDisabledFactory() public {
        adapter.configure(false,false,false,0,false,USER,HOOK);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("take(address,address,uint256)",address(adapter),USER,0),0);
        require(!ok&&bytes4(out)==PermissionedV4Router.SwappingDisabled.selector);
        (ok,)=compare(abi.encodeWithSignature("handle(uint256,bytes)",11,abi.encode(address(adapter),uint256(0),true)),0);require(!ok); // debt is nonzero
        manager.configure(0,-7,11);
        (ok,)=compare(abi.encodeWithSignature("handle(uint256,bytes)",11,abi.encode(address(adapter),uint256(0),true)),0);require(ok); // settle short-circuits
        configureFactory(address(0));registry.configure(2,true);
        (ok,)=compare(abi.encodeWithSignature("validate((address,address,uint24,int24,address))",key()),0);require(ok);
        (ok,)=compare(abi.encodeWithSignature("take(address,address,uint256)",address(adapter),USER,0),0);require(ok);
        (ok,)=compare(abi.encodeWithSignature("pay(address,address,uint256)",address(adapter),USER,5),0);require(ok);
    }
    function test_rawResponsesAndMalformedCalls() public {
        for(uint8 shape;shape<4;++shape) {
            registry.configure(shape,false);
            compare(abi.encodeWithSignature("mapSettle(uint256,address)",5,address(adapter)),0);
            compare(abi.encodeWithSignature("take(address,address,uint256)",address(adapter),USER,0),0);
        }
        registry.configure(0,false);
        for(uint8 shape;shape<4;++shape) {
            adapter.configure(true,true,true,shape,false,USER,HOOK);
            compare(abi.encodeWithSignature("pay(address,address,uint256)",address(adapter),USER,0),0);
        }
        registry.configure(0,true);compare(abi.encodeWithSignature("mapSettle(uint256,address)",5,address(adapter)),0);
        compare(hex"",0);compare(hex"12345678",0);
        compare(abi.encodeWithSignature("take(address,address,uint256)",address(adapter),USER,0),1);
        compare(abi.encodePacked(bytes4(keccak256("pay(address,address,uint256)")),bytes32(type(uint256).max),bytes32(0),bytes32(0)),0);
    }
    function test_multihopChecksEachPool() public {
        PathKey[] memory path=new PathKey[](2);
        path[0]=PathKey(Currency.wrap(address(other)),3000,60,IHooks(HOOK),"");
        path[1]=PathKey(Currency.wrap(address(asset)),3000,60,IHooks(HOOK),"");
        other.configure(true,true,false,0,false,USER,HOOK);
        for(uint256 action=7;action<=9;action+=2) {
            (bool ok,bytes memory out)=compare(abi.encodeWithSignature("handle(uint256,bytes)",action,abi.encode(IV4Router.ExactInputParams(Currency.wrap(address(adapter)),path,new uint256[](0),7,0))),0);
            require(!ok&&bytes4(out)==PermissionedV4Router.HookNotAllowed.selector);
        }
    }
}
