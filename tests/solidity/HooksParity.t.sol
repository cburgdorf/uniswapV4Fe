// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Hooks} from "./reference/src/libraries/Hooks.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {ModifyLiquidityParams,SwapParams} from "./reference/src/types/PoolOperation.sol";
import {BalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "./reference/src/types/BeforeSwapDelta.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function etch(address,bytes calldata) external;
    function prank(address) external;
}
contract SolidityHooksHarness {
    using Hooks for IHooks;
    function permissions(address target,uint24 fee,uint256 flag) external pure returns(bool,bool) { return (IHooks(target).isValidHookAddress(fee),IHooks(target).hasPermission(uint160(flag))); }
    function validate(address target,uint256 flags) external pure {
        Hooks.Permissions memory p;
        p.beforeInitialize=flags&8192!=0;p.afterInitialize=flags&4096!=0;
        p.beforeAddLiquidity=flags&2048!=0;p.afterAddLiquidity=flags&1024!=0;
        p.beforeRemoveLiquidity=flags&512!=0;p.afterRemoveLiquidity=flags&256!=0;
        p.beforeSwap=flags&128!=0;p.afterSwap=flags&64!=0;p.beforeDonate=flags&32!=0;p.afterDonate=flags&16!=0;
        p.beforeSwapReturnDelta=flags&8!=0;p.afterSwapReturnDelta=flags&4!=0;p.afterAddLiquidityReturnDelta=flags&2!=0;p.afterRemoveLiquidityReturnDelta=flags&1!=0;
        IHooks(target).validateHookPermissions(p);
    }
    function raw(address target,bytes memory data,bool delta,bool parse) external returns(bytes memory) {
        if(delta) return abi.encode(IHooks(target).callHookWithReturnDelta(data,parse));
        return IHooks(target).callHook(data);
    }
    function initializeHook(PoolKey memory key,uint160 price,int24 tick,bool after_) external { if(after_) key.hooks.afterInitialize(key,price,tick); else key.hooks.beforeInitialize(key,price); }
    function beforeModify(PoolKey memory key,ModifyLiquidityParams memory params,bytes calldata data) external { key.hooks.beforeModifyLiquidity(key,params,data); }
    function afterModify(PoolKey memory key,ModifyLiquidityParams memory params,int256 delta,int256 fees,bytes calldata data) external returns(int256,int256) {
        (BalanceDelta a,BalanceDelta b)=key.hooks.afterModifyLiquidity(key,params,BalanceDelta.wrap(delta),BalanceDelta.wrap(fees),data);return (BalanceDelta.unwrap(a),BalanceDelta.unwrap(b));
    }
    function beforeSwap(PoolKey memory key,SwapParams memory params,bytes calldata data) external returns(int256,int256,uint24) {
        (int256 a,BeforeSwapDelta b,uint24 c)=key.hooks.beforeSwap(key,params,data);return (a,BeforeSwapDelta.unwrap(b),c);
    }
    function afterSwap(PoolKey memory key,SwapParams memory params,int256 delta,bytes calldata data,int256 before_) external returns(int256,int256) {
        (BalanceDelta a,BalanceDelta b)=key.hooks.afterSwap(key,params,BalanceDelta.wrap(delta),data,BeforeSwapDelta.wrap(before_));return (BalanceDelta.unwrap(a),BalanceDelta.unwrap(b));
    }
    function donateHook(PoolKey memory key,uint256 amount0,uint256 amount1,bytes calldata data,bool after_) external { if(after_) key.hooks.afterDonate(key,amount0,amount1,data);else key.hooks.beforeDonate(key,amount0,amount1,data); }
}
contract HookResponder {
    uint256 public calls;
    bytes32 public lastData;
    uint256 size;
    int256 delta;
    uint256 fee;
    bool failure;
    bool wrong;
    function configure(uint256 len,int256 d,uint256 f,bool fail,bool mismatch) external { calls=0;lastData=0;size=len;delta=d;fee=f;failure=fail;wrong=mismatch; }
    fallback() external {
        calls++;lastData=keccak256(msg.data);
        uint256 n=size;bytes memory result=new bytes(n<96?96:n);
        uint256 selectorWord=uint256(uint32(msg.sig))<<224;
        if(wrong) selectorWord^=uint256(1)<<224;
        selectorWord|=12345; // Dirty bytes4 padding is deliberately accepted by Hooks.
        int256 d=delta;uint256 f=fee;
        assembly { mstore(add(result,32),selectorWord) mstore(add(result,64),d) mstore(add(result,96),f) }
        if(failure) { assembly { revert(add(result,32),n) } }
        assembly { return(add(result,32),n) }
    }
}
contract HooksParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityHooksHarness sol;
    HookResponder responder;
    address hook;
    address sender;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address deployed;
        assembly { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityHooksHarness();responder=new HookResponder();
    }
    function configure(uint16 flags,uint256 len,int256 delta,uint256 fee,bool fail,bool wrong) internal returns(PoolKey memory key) {
        hook=address(uint160(0x100000 | (flags&0x3fff)));vm.etch(hook,address(responder).code);
        HookResponder(hook).configure(len,delta,fee,fail,wrong);
        key=PoolKey(Currency.wrap(address(0x111111)),Currency.wrap(address(0x222222)),0x800000,-17,IHooks(hook));
    }
    function compare(bytes memory data) internal returns(bool ok,bytes memory out) {
        uint256 previous=hook==address(0)?0:HookResponder(hook).calls();
        if(sender!=address(0))vm.prank(sender);
        (ok,out)=fe.call{gas:3000000}(data);
        uint256 middle=hook==address(0)?0:HookResponder(hook).calls();
        bytes32 first=hook==address(0)?bytes32(0):HookResponder(hook).lastData();
        if(sender!=address(0))vm.prank(sender);
        (bool other,bytes memory expected)=address(sol).call{gas:3000000}(data);
        require(ok==other,"success mismatch");require(keccak256(out)==keccak256(expected),"return/revert mismatch");
        if(hook!=address(0)) {
            uint256 last=HookResponder(hook).calls();require(middle-previous==last-middle,"callback count mismatch");
            if(middle>previous)require(first==HookResponder(hook).lastData(),"callback calldata mismatch");
        }
    }
    function testFuzz_permissions(address target,uint24 fee,uint160 flag,uint256 mask) public {
        compare(abi.encodeCall(sol.permissions,(target,fee,uint256(flag))));
        compare(abi.encodeCall(sol.validate,(target,mask)));
        (bool ok,)=compare(abi.encodeCall(sol.validate,(target,uint160(target)&0x3fff)));require(ok,"matching permission mask");
    }
    function testFuzz_raw(bytes4 selector,uint8 length,int256 delta,uint256 fee,bool failure,bool wrong,bool parse) public {
        configure(0,length,delta,fee,failure,wrong);
        bytes memory data=abi.encodePacked(selector,bytes32(uint256(17)));
        compare(abi.encodeCall(sol.raw,(hook,data,false,false)));
        compare(abi.encodeCall(sol.raw,(hook,data,true,parse)));
    }
    function testFuzz_initializeDonate(uint16 flags,uint160 price,int24 tick,uint256 amount,uint8 length,bool wrong,bytes memory data) public {
        PoolKey memory key=configure(flags,length,0,0,false,wrong);
        compare(abi.encodeCall(sol.initializeHook,(key,price,tick,false)));
        compare(abi.encodeCall(sol.initializeHook,(key,price,tick,true)));
        compare(abi.encodeCall(sol.donateHook,(key,amount,type(uint256).max,data,false)));
        compare(abi.encodeCall(sol.donateHook,(key,amount,0,data,true)));
    }
    function testFuzz_modify(uint16 flags,int256 liquidity,int256 delta,int256 returned,uint8 length,bytes memory data) public {
        PoolKey memory key=configure(flags,length,returned,0,false,false);
        ModifyLiquidityParams memory params=ModifyLiquidityParams(-8388608,8388607,liquidity,bytes32(uint256(0x12345)));
        compare(abi.encodeCall(sol.beforeModify,(key,params,data)));
        compare(abi.encodeCall(sol.afterModify,(key,params,delta,int256(-1),data)));
    }
    function testFuzz_beforeSwap(uint16 flags,int256 amount,int256 returned,uint256 fee,uint8 length,bool direction,bool dynamicFee,bytes memory data) public {
        PoolKey memory key=configure(flags,length,returned,fee,false,false);if(!dynamicFee)key.fee=3000;
        SwapParams memory params=SwapParams(direction,amount,type(uint160).max);
        compare(abi.encodeCall(sol.beforeSwap,(key,params,data)));
    }
    function testFuzz_afterSwap(uint16 flags,int256 amount,int256 returned,int256 delta,int256 before_,uint8 length,bool direction,bytes memory data) public {
        PoolKey memory key=configure(flags,length,returned,0,false,false);
        SwapParams memory params=SwapParams(direction,amount,1);
        compare(abi.encodeCall(sol.afterSwap,(key,params,delta,data,before_)));
    }
    function testFuzz_validSwapDeltas(int128 specified,int128 unspecified,int128 afterDelta,bool direction,bool exactInput,bytes memory data) public {
        int256 packed=(int256(specified)<<128)|int256(uint256(uint128(unspecified)));
        PoolKey memory key=configure(0x00cc,96,packed,0x400123,false,false);
        int256 amount=exactInput?-(int256(1)<<200):(int256(1)<<200);
        SwapParams memory params=SwapParams(direction,amount,12345);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.beforeSwap,(key,params,data)));
        require(ok,"valid before swap");
        (int256 adjusted,int256 returned,uint24 fee)=abi.decode(out,(int256,int256,uint24));
        require(adjusted==amount+specified && returned==packed && fee==0x400123,"before swap model");
        HookResponder(hook).configure(64,afterDelta,0,false,false);
        (ok,out)=compare(abi.encodeCall(sol.afterSwap,(key,params,int256(0),data,packed)));
        int256 sum=int256(unspecified)+afterDelta;
        bool fits=sum>=type(int128).min && sum<=type(int128).max;
        bool canNegate=specified!=type(int128).min && sum!=type(int128).min;
        require(ok==(fits && canNegate),"after swap overflow model");
        if(ok) {
            (int256 callerDelta,int256 hookDelta)=abi.decode(out,(int256,int256));
            int128 a=exactInput==direction?specified:int128(sum);
            int128 b=exactInput==direction?int128(sum):specified;
            require(hookDelta==((int256(a)<<128)|int256(uint256(uint128(b)))),"hook delta mapping");
            require(callerDelta==((int256(-a)<<128)|int256(uint256(uint128(-b)))),"caller subtraction");
        }
    }
    function testFuzz_validLiquidityDeltas(int128 a,int128 b,bool adding,bytes memory data) public {
        int256 packed=(int256(a)<<128)|int256(uint256(uint128(b)));
        PoolKey memory key=configure(0x0f03,64,packed,0,false,false);
        ModifyLiquidityParams memory params=ModifyLiquidityParams(-17,19,adding?int256(1):int256(0),bytes32(uint256(7)));
        (bool ok,)=compare(abi.encodeCall(sol.beforeModify,(key,params,data)));require(ok,"before modify valid");
        bytes memory out;(ok,out)=compare(abi.encodeCall(sol.afterModify,(key,params,int256(0),int256(0),data)));
        require(ok==(a!=type(int128).min && b!=type(int128).min),"liquidity delta overflow");
        if(ok) {
            (int256 callerDelta,int256 hookDelta)=abi.decode(out,(int256,int256));
            require(hookDelta==packed && callerDelta==((int256(-a)<<128)|int256(uint256(uint128(-b)))),"liquidity delta model");
        }
    }
    function test_shortCallsAndCodelessTarget() public {
        configure(0,32,0,0,false,false);
        for(uint256 len;len<4;len++) {
            bytes memory data=new bytes(len);
            for(uint256 i;i<len;i++)data[i]=bytes1(uint8(i+1));
            compare(abi.encodeCall(sol.raw,(hook,data,false,false)));
        }
        (bool ok,)=compare(abi.encodeCall(sol.raw,(address(0xdeadbeef),hex"12345678",false,false)));
        require(!ok,"empty codeless response must fail");
    }
    function test_successfulDispatchAndSelfCall() public {
        PoolKey memory key=configure(0x3fff,32,0,0,false,false);
        (bool ok,)=compare(abi.encodeCall(sol.initializeHook,(key,uint160(17),int24(-9),false)));require(ok,"before init");
        (ok,)=compare(abi.encodeCall(sol.initializeHook,(key,uint160(17),int24(-9),true)));require(ok,"after init");
        bytes memory data=hex"deadbeef123456";
        (ok,)=compare(abi.encodeCall(sol.donateHook,(key,9,11,data,false)));require(ok,"before donate");
        (ok,)=compare(abi.encodeCall(sol.donateHook,(key,9,11,data,true)));require(ok,"after donate");
        for(uint256 i;i<3;i++) {
            ModifyLiquidityParams memory p=ModifyLiquidityParams(-30,90,i==0?int256(1):i==1?int256(0):int256(-1),bytes32(uint256(7)));
            (ok,)=compare(abi.encodeCall(sol.beforeModify,(key,p,data)));require(ok,"before liquidity");
            HookResponder(hook).configure(64,0,0,false,false);
            (ok,)=compare(abi.encodeCall(sol.afterModify,(key,p,int256(0),int256(-1),data)));require(ok,"after liquidity");
        }
        HookResponder(hook).configure(96,0,type(uint256).max,false,false);
        SwapParams memory p=SwapParams(true,-100,17);
        bytes memory result;
        (ok,result)=compare(abi.encodeCall(sol.beforeSwap,(key,p,data)));require(ok,"before swap");
        (int256 amount,int256 d,uint24 fee)=abi.decode(result,(int256,int256,uint24));require(amount==-100 && d==0 && fee==0xffffff,"dirty fee truncation");
        HookResponder(hook).configure(64,1,0,false,false);
        (ok,)=compare(abi.encodeCall(sol.afterSwap,(key,p,int256(0),data,int256(0))));require(ok,"after swap");
        // Every helper must skip the callback when the hook itself is the caller.
        sender=hook;HookResponder(hook).configure(0,0,0,true,true);
        (ok,)=compare(abi.encodeCall(sol.initializeHook,(key,uint160(17),int24(-9),false)));require(ok,"self init");
        (ok,)=compare(abi.encodeCall(sol.initializeHook,(key,uint160(17),int24(-9),true)));require(ok,"self after init");
        ModifyLiquidityParams memory modify=ModifyLiquidityParams(-1,1,1,bytes32(0));
        (ok,)=compare(abi.encodeCall(sol.beforeModify,(key,modify,data)));require(ok,"self before modify");
        (ok,)=compare(abi.encodeCall(sol.afterModify,(key,modify,int256(0),int256(0),data)));require(ok,"self after modify");
        (ok,)=compare(abi.encodeCall(sol.beforeSwap,(key,p,data)));require(ok,"self before swap");
        (ok,)=compare(abi.encodeCall(sol.afterSwap,(key,p,int256(0),data,int256(7))));require(ok,"self after swap");
        (ok,)=compare(abi.encodeCall(sol.donateHook,(key,1,2,data,false)));require(ok,"self donate");
        (ok,)=compare(abi.encodeCall(sol.donateHook,(key,1,2,data,true)));require(ok && HookResponder(hook).calls()==0,"self after donate");sender=address(0);
    }
    function test_responseLengthsAndSwapBoundaries() public {
        uint8[12] memory lengths=[uint8(0),1,4,31,32,33,63,64,65,95,96,97];
        for(uint256 i;i<lengths.length;i++) {
            testFuzz_raw(0x12345678,lengths[i],-1,type(uint256).max,false,false,true);
            testFuzz_raw(0x12345678,lengths[i],0,0,true,false,false);
            testFuzz_beforeSwap(136,-100,0,0,lengths[i],true,true,hex"01");
            testFuzz_afterSwap(68,-100,0,0,0,lengths[i],true,hex"01");
        }
        testFuzz_beforeSwap(136,-100,int256(101)<<128,0,96,true,true,bytes(""));
        testFuzz_beforeSwap(136,100,int256(-101)<<128,0,96,false,true,bytes(""));
        testFuzz_beforeSwap(136,type(int256).max,int256(1)<<128,0,96,true,true,bytes(""));
        testFuzz_beforeSwap(136,type(int256).min,int256(-1)<<128,0,96,true,true,bytes(""));
        testFuzz_beforeSwap(136,-100,int256(100)<<128,0,96,true,true,bytes(""));
        testFuzz_afterSwap(68,-1,type(int256).max,0,0,64,true,bytes(""));
        testFuzz_afterSwap(68,-1,1,0,int256(uint256(uint128(type(int128).max))),64,true,bytes(""));
        testFuzz_modify(1026,1,type(int256).min,int256(1)<<128,64,bytes(""));
    }
    function test_zeroAndFlaglessAddresses() public {
        (bool ok,bytes memory result)=compare(abi.encodeCall(sol.permissions,(address(0),uint24(0),uint256(0))));require(ok && abi.decode(result,(bool)),"zero static");
        compare(abi.encodeCall(sol.permissions,(address(0),uint24(0x800000),uint256(0))));
        compare(abi.encodeCall(sol.permissions,(address(0x100000),uint24(0x800000),uint256(0))));
        compare(abi.encodeCall(sol.permissions,(address(0x100000),uint24(0),uint256(0))));
    }
}
