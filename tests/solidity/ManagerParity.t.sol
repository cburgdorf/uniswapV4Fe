// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams,SwapParams} from "./reference/src/types/PoolOperation.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
    function deal(address,uint256) external;
    function prank(address) external;
    function etch(address,bytes calldata) external;
    function load(address,bytes32) external view returns(bytes32);
}
contract ManagerToken {
    mapping(address=>uint256) public balanceOf;
    function mint(address to,uint256 n) external {balanceOf[to]+=n;}
    function transfer(address to,uint256 n) external returns(bool) {balanceOf[msg.sender]-=n;balanceOf[to]+=n;return true;}
}
struct Action {bytes data;uint256 value;}
contract ManagerActor {
    address manager;
    receive() external payable {}
    function run(address target,Action[] memory actions,address[] memory currencies,bool net,bytes memory result) external returns(bytes memory) {
        manager=target;
        return IPoolManager(target).unlock(abi.encode(actions,currencies,net,result));
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender==manager,"callback caller");
        (Action[] memory actions,address[] memory currencies,bool net,bytes memory result)=abi.decode(data,(Action[],address[],bool,bytes));
        bytes memory returnedData;
        for(uint256 i;i<actions.length;i++) {
            (bool ok,bytes memory out)=manager.call{value:actions[i].value}(actions[i].data);
            if(!ok) assembly ("memory-safe") {revert(add(out,32),mload(out))}
            returnedData=bytes.concat(returnedData,out);
        }
        if(net) for(uint256 i;i<currencies.length;i++) {
            Currency currency=Currency.wrap(currencies[i]);
            int256 delta=int256(uint256(IPoolManager(manager).exttload(keccak256(abi.encode(address(this),currencies[i])))));
            if(delta<0) {
                uint256 amount=uint256(-delta);IPoolManager(manager).sync(currency);
                if(currencies[i]==address(0))require(IPoolManager(manager).settle{value:amount}()==amount,"native paid");
                else {ManagerToken(currencies[i]).transfer(manager,amount);require(IPoolManager(manager).settle()==amount,"token paid");}
            } else if(delta>0) IPoolManager(manager).take(currency,address(this),uint256(delta));
        }
        return bytes.concat(returnedData,result);
    }
}
contract RawUnlockActor {
    bytes response;
    bool failure;
    function configure(bytes memory data,bool fail) external {response=data;failure=fail;}
    function run(address target,bytes memory data) external returns(bytes memory) {return IPoolManager(target).unlock(data);}
    fallback() external {
        require(msg.sig==bytes4(keccak256("unlockCallback(bytes)")),"callback selector");
        bytes memory data=response;bool fail=failure;
        assembly ("memory-safe") {if fail {revert(add(data,32),mload(data))} return(add(data,32),mload(data))}
    }
}
contract LifecycleHook {
    receive() external payable {}
    bytes32 public trace;
    uint256 public calls;
    uint8 public mode;
    function reset(uint8 value) external {trace=0;calls=0;mode=value;}
    fallback() external {
        calls++;trace=keccak256(abi.encode(trace,msg.data));
        if(mode==1) revert("hook rejected");
        if(mode==2) {
            (bool ok,bytes memory out)=msg.sender.call(abi.encodeCall(IPoolManager.unlock,(bytes(""))));
            require(!ok && bytes4(out)==bytes4(keccak256("AlreadyUnlocked()")),"reentrant lock");
        }
        uint256 n=msg.sig==IHooks.beforeSwap.selector?96:64;
        bytes memory result=new bytes(n);uint256 selectorWord=uint256(uint32(msg.sig))<<224;
        int256 delta;
        if(mode==4 && msg.sig==IHooks.afterAddLiquidity.selector) {
            IPoolManager(msg.sender).take(Currency.wrap(address(0)),address(this),1);
            delta=int256(1)<<128;
        }
        if(mode==3 || (mode==5 && msg.sig==IHooks.afterAddLiquidity.selector)) selectorWord=0;
        assembly {mstore(add(result,32),selectorWord) mstore(add(result,64),delta) return(add(result,32),n)}
    }
}
contract DelegateProxy {
    function invoke(address target,bytes calldata data) external returns(bool,bytes memory) {return target.delegatecall(data);}
}
contract ManagerParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    address fe;
    PoolManager sol;
    ManagerActor actor;
    ManagerToken token;
    RawUnlockActor rawActor;
    PoolKey key;
    bool observeHook;
    uint8 hookMode;
    function setUp() public {
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(this)));
        address deployed;assembly ("memory-safe") {deployed:=create(0,add(code,32),mload(code))}
        require(deployed.code.length>0,"Fe deploy / code size");fe=deployed;sol=new PoolManager(address(this));actor=new ManagerActor();token=new ManagerToken();rawActor=new RawUnlockActor();
        key=PoolKey(Currency.wrap(address(0)),Currency.wrap(address(token)),3000,60,IHooks(address(0)));
        vm.deal(address(actor),1<<120);token.mint(address(actor),1<<120);
    }
    function equalLogs(Vm.Log[] memory a,Vm.Log[] memory b) internal view {
        require(a.length==b.length,"logs count");
        for(uint256 i;i<a.length;i++) {
            require(a[i].emitter==fe && b[i].emitter==address(sol),"logs emitter");
            require(keccak256(abi.encode(a[i].topics,a[i].data))==keccak256(abi.encode(b[i].topics,b[i].data)),"logs data");
        }
    }
    function compare(bytes memory data) internal returns(bool ok,bytes memory out) { return compareFrom(address(this),data); }
    function compareFrom(address caller,bytes memory data) internal returns(bool ok,bytes memory out) {
        if(observeHook) LifecycleHook(payable(address(key.hooks))).reset(hookMode);
        vm.recordLogs();vm.prank(caller);(ok,out)=fe.call(data);Vm.Log[] memory a=vm.getRecordedLogs();
        bytes32 trace;uint256 count;
        if(observeHook) {trace=LifecycleHook(payable(address(key.hooks))).trace();count=LifecycleHook(payable(address(key.hooks))).calls();LifecycleHook(payable(address(key.hooks))).reset(hookMode);}
        vm.recordLogs();vm.prank(caller);(bool other,bytes memory expected)=address(sol).call(data);Vm.Log[] memory b=vm.getRecordedLogs();
        require(ok==other,"direct status");require(keccak256(out)==keccak256(expected),"direct bytes");equalLogs(a,b);
        if(observeHook) require(trace==LifecycleHook(payable(address(key.hooks))).trace() && count==LifecycleHook(payable(address(key.hooks))).calls(),"direct hook trace");
    }
    function run(Action[] memory actions,bool net,bytes memory result) internal returns(bool ok,bytes memory out) {
        address[] memory currencies=new address[](2);currencies[1]=address(token);
        if(observeHook) LifecycleHook(payable(address(key.hooks))).reset(hookMode);
        vm.recordLogs();(ok,out)=address(actor).call(abi.encodeCall(actor.run,(fe,actions,currencies,net,result)));Vm.Log[] memory a=vm.getRecordedLogs();
        bytes32 trace;uint256 count;
        if(observeHook) {trace=LifecycleHook(payable(address(key.hooks))).trace();count=LifecycleHook(payable(address(key.hooks))).calls();LifecycleHook(payable(address(key.hooks))).reset(hookMode);}
        vm.recordLogs();(bool other,bytes memory expected)=address(actor).call(abi.encodeCall(actor.run,(address(sol),actions,currencies,net,result)));Vm.Log[] memory b=vm.getRecordedLogs();
        require(ok==other,"unlock status");require(keccak256(out)==keccak256(expected),"unlock bytes");equalLogs(a,b);
        if(observeHook) require(trace==LifecycleHook(payable(address(key.hooks))).trace() && count==LifecycleHook(payable(address(key.hooks))).calls(),"lifecycle hook trace");
        require(fe.balance==address(sol).balance,"native balance parity");require(token.balanceOf(fe)==token.balanceOf(address(sol)),"token balance parity");
        require(IPoolManager(fe).exttload(LOCK)==0 && sol.exttload(LOCK)==0,"lock restored");
        require(IPoolManager(fe).exttload(COUNT)==0 && sol.exttload(COUNT)==0,"deltas cleared");
        bytes32 root=keccak256(abi.encode(key.toId(),uint256(6)));
        require(keccak256(abi.encode(IPoolManager(fe).extsload(root,7)))==keccak256(abi.encode(sol.extsload(root,7))),"pool header parity");
    }
    function initialize() internal { (bool ok,)=compare(abi.encodeCall(sol.initialize,(key,uint160(1<<96))));require(ok,"initialize"); }
    function testFuzz_initialize(uint160 price,int24 spacing,uint24 fee) public {
        PoolKey memory k=key;k.tickSpacing=spacing;k.fee=fee;
        compare(abi.encodeCall(sol.initialize,(k,price)));
    }
    function testFuzz_unlockEcho(bytes memory data) public {
        Action[] memory a=new Action[](0);(bool ok,bytes memory out)=run(a,true,data);require(ok,"empty unlock");require(keccak256(abi.decode(out,(bytes)))==keccak256(data),"echo");
    }
    function testFuzz_lifecycle(uint64 rawLiquidity,uint32 rawSwap,uint32 rawDonation,bool direction) public {
        initialize();uint256 liquidity=uint256(rawLiquidity)%1e15+1000000000;uint256 amount=uint256(rawSwap)%10000+1;
        Action[] memory a=new Action[](5);
        a[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,int256(liquidity),0),bytes("")));
        a[1].data=abi.encodeCall(sol.swap,(key,SwapParams(direction,-int256(amount),direction?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341)),bytes("")));
        a[2].data=abi.encodeCall(sol.donate,(key,uint256(rawDonation)%100,uint256(rawDonation)%57,bytes("")));
        a[3].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,0,0),bytes("")));
        a[4].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,-int256(liquidity),0),bytes("")));
        (bool ok,)=run(a,true,hex"abcd");require(ok,"lifecycle");
    }
    function testFuzz_claims(uint64 amount,bool native,uint96 high) public {
        address currency=native?address(0):address(token);uint256 id=(uint256(high)<<160)|uint160(currency);
        Action[] memory a=new Action[](1);a[0].data=abi.encodeCall(sol.mint,(address(actor),id,amount));(bool ok,)=run(a,true,"");require(ok,"claim mint");
        require(IPoolManager(fe).balanceOf(address(actor),uint160(currency))==amount,"truncated claim id");
        a[0].data=abi.encodeCall(sol.burn,(address(actor),id,amount));(ok,)=run(a,true,"");require(ok,"claim burn");
        require(IPoolManager(fe).balanceOf(address(actor),uint160(currency))==0,"burn balance");
    }
    function test_lockedMethodsAndDelegateCall() public {
        initialize();
        compare(abi.encodeCall(sol.take,(Currency.wrap(address(0)),address(actor),1)));
        compare(abi.encodeCall(sol.settle,()));compare(abi.encodeCall(sol.settleFor,(address(actor))));
        compare(abi.encodeCall(sol.clear,(Currency.wrap(address(0)),0)));
        compare(abi.encodeCall(sol.mint,(address(actor),0,1)));compare(abi.encodeCall(sol.burn,(address(actor),0,1)));
        compare(abi.encodeCall(sol.swap,(key,SwapParams(true,0,1),bytes(""))));
        DelegateProxy proxy=new DelegateProxy();bytes memory data=abi.encodeCall(sol.initialize,(key,uint160(1<<96)));
        (bool a,bytes memory x)=proxy.invoke(fe,data);(bool b,bytes memory y)=proxy.invoke(address(sol),data);
        require(!a && !b && keccak256(x)==keccak256(y) && bytes4(x)==bytes4(keccak256("DelegateCallNotAllowed()")),"immutable delegate guard");
    }
    function test_unlockRollbackAndReentry() public {
        vm.deal(fe,100);vm.deal(address(sol),100);
        Action[] memory a=new Action[](1);a[0].data=abi.encodeCall(sol.take,(Currency.wrap(address(0)),address(actor),1));
        (bool ok,bytes memory out)=run(a,false,"");require(!ok && bytes4(out)==bytes4(keccak256("CurrencyNotSettled()")),"unsettled rollback");require(fe.balance==100,"transfer rolled back");
        a[0].data=abi.encodeCall(sol.unlock,(bytes("")));(ok,out)=run(a,false,"");require(!ok && bytes4(out)==bytes4(keccak256("AlreadyUnlocked()")),"nested unlock");
    }
    function test_settleForAndClear() public {
        Action[] memory a=new Action[](2);a[0]=Action(abi.encodeCall(sol.settleFor,(address(actor))),123);a[1].data=abi.encodeCall(sol.clear,(Currency.wrap(address(0)),123));
        (bool ok,)=run(a,false,"");require(ok && fe.balance==123,"settleFor clear");
    }
    function test_protocolFeeAccrualAndCollection() public {
        initialize();compare(abi.encodeCall(sol.setProtocolFeeController,(address(this))));
        compare(abi.encodeCall(sol.setProtocolFee,(key,uint24(500|(500<<12)))));
        Action[] memory a=new Action[](2);
        a[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,1e12,0),bytes("")));
        a[1].data=abi.encodeCall(sol.swap,(key,SwapParams(true,-1e8,4295128740),bytes("")));
        (bool ok,)=run(a,true,"");require(ok,"fee swap");
        uint256 fee=sol.protocolFeesAccrued(Currency.wrap(address(0)));
        require(fee>0 && IPoolManager(fe).protocolFeesAccrued(Currency.wrap(address(0)))==fee,"accrued fee");
        bytes memory out;(ok,out)=compare(abi.encodeCall(sol.collectProtocolFees,(address(actor),Currency.wrap(address(0)),0)));
        require(ok && abi.decode(out,(uint256))==fee,"fee collection");require(fe.balance==address(sol).balance,"fee balances");
    }
    function test_dynamicLPFeeAuthorization() public {
        PoolKey memory k=key;k.fee=0x800000;k.hooks=IHooks(address(0x4000));
        (bool ok,)=compare(abi.encodeCall(sol.initialize,(k,uint160(1<<96))));require(ok,"dynamic initialize");
        bytes memory out;(ok,out)=compare(abi.encodeCall(sol.updateDynamicLPFee,(k,uint24(1234))));
        require(!ok && bytes4(out)==bytes4(keccak256("UnauthorizedDynamicLPFeeUpdate()")),"dynamic authorization");
        (ok,)=compareFrom(address(k.hooks),abi.encodeCall(sol.updateDynamicLPFee,(k,uint24(1234))));require(ok,"hook fee update");
        bytes32 slot=keccak256(abi.encode(k.toId(),uint256(6)));require(IPoolManager(fe).extsload(slot)==sol.extsload(slot),"dynamic fee slot");
        (ok,)=compareFrom(address(k.hooks),abi.encodeCall(sol.updateDynamicLPFee,(k,uint24(1000001))));require(!ok,"LP fee bound");
    }

    function testFuzz_callbackReturn(uint8 size,uint256 offset,uint256 length,bool failure) public {
        bytes memory response=new bytes(size);for(uint256 i;i<size;i++)response[i]=bytes1(uint8(i));
        if(size>=32)assembly ("memory-safe") {mstore(add(response,32),offset)}
        if(size>=64)assembly ("memory-safe") {mstore(add(response,64),length)}
        rawActor.configure(response,failure);
        (bool ok,bytes memory out)=address(rawActor).call(abi.encodeCall(rawActor.run,(fe,bytes("hello"))));
        (bool other,bytes memory expected)=address(rawActor).call(abi.encodeCall(rawActor.run,(address(sol),bytes("hello"))));
        require(ok==other && keccak256(out)==keccak256(expected),"raw callback return parity");
        require(IPoolManager(fe).exttload(LOCK)==0 && sol.exttload(LOCK)==0,"callback rollback lock");
    }
    function test_shortUnpaddedCallbackReturn() public {
        rawActor.configure(bytes.concat(abi.encode(uint256(32),uint256(3)),hex"112233"),false);
        bytes memory a=rawActor.run(fe,"");bytes memory b=rawActor.run(address(sol),"");require(keccak256(a)==keccak256(b) && keccak256(a)==keccak256(hex"112233"),"unpadded return");
        testFuzz_callbackReturn(64,0,0,false);
        testFuzz_callbackReturn(32,0,0,false);
    }

    function test_callbackAllocationPrecedesBounds() public {
        testFuzz_callbackReturn(65,11,500,false);
        testFuzz_callbackReturn(64,32,type(uint256).max,false);
        testFuzz_callbackReturn(64,32,type(uint64).max,false);
        testFuzz_callbackReturn(64,32,type(uint64).max-255,false);
        testFuzz_callbackReturn(64,32,500,false);
    }

    function enableHooks() internal {
        LifecycleHook template=new LifecycleHook();
        address hook=address(0x103fff);vm.etch(hook,address(template).code);
        key.hooks=IHooks(hook);observeHook=true;hookMode=0;
    }
    function testFuzz_hookLifecycle(uint32 liquidity,uint16 amount,bool direction,bool reenter) public {
        enableHooks();
        // Initialization is locked; test reentry only during the unlock lifecycle.
        initialize();hookMode=reenter?2:0;
        Action[] memory a=new Action[](4);
        a[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,int256(uint256(liquidity)+1000000),0),hex"1234"));
        a[1].data=abi.encodeCall(sol.swap,(key,SwapParams(direction,-int256(uint256(amount)+1),direction?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341)),hex"deadbeef"));
        a[2].data=abi.encodeCall(sol.donate,(key,uint256(17),uint256(29),hex"5678"));
        a[3].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,-int256(uint256(liquidity)+1000000),0),hex"abcd"));
        (bool ok,bytes memory out)=run(a,true,"");
        if(ok) require(LifecycleHook(payable(address(key.hooks))).calls()==8,"all lifecycle callbacks");
        else {
            // A large swap can leave the finite range before the donation.
            require(bytes4(out)==bytes4(keccak256("NoLiquidityToReceiveFees()")),"exhausted liquidity revert");
            require(LifecycleHook(payable(address(key.hooks))).calls()==0,"hook trace rolled back");
        }
    }
    function test_hookFailureAndWrongSelectorRollBack() public {
        enableHooks();initialize();
        bytes32 root=keccak256(abi.encode(key.toId(),uint256(6)));
        bytes32 beforeSlot=IPoolManager(fe).extsload(root);
        Action[] memory a=new Action[](1);
        a[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,1000000,0),bytes("")));
        hookMode=1;(bool ok,)=run(a,true,"");require(!ok,"hook revert");
        hookMode=3;(ok,)=run(a,true,"");require(!ok,"wrong selector");
        hookMode=5;(ok,)=run(a,true,"");require(!ok,"after-add rollback");
        require(IPoolManager(fe).extsload(root)==beforeSlot,"hook rollback state");
        Action[] memory probe=new Action[](1);
        probe[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,-1000000,0),bytes("")));
        hookMode=0;(ok,)=run(probe,true,"");require(!ok,"reverted position has no liquidity");
    }

    function test_hookReturnedDeltaAndSettlement() public {
        enableHooks();initialize();hookMode=4;
        vm.deal(fe,1);vm.deal(address(sol),1);
        Action[] memory a=new Action[](1);
        a[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(-120,120,1000000,0),bytes("")));
        (bool ok,)=run(a,true,"");require(ok,"hook delta settlement");
        require(address(key.hooks).balance==2,"one native unit per manager");
        bytes32 slot=keccak256(abi.encode(address(key.hooks),address(0)));
        require(IPoolManager(fe).exttload(slot)==0 && sol.exttload(slot)==0,"hook delta cleared");
    }

    function test_hookLifecycleSuccessAndExhaustion() public {
        testFuzz_hookLifecycle(1024,100,true,true);
        require(LifecycleHook(payable(address(key.hooks))).calls()==8,"successful reentrant lifecycle");
        // Use a distinct pool to avoid the already-initialized guard.
        key.fee=3001;
        testFuzz_hookLifecycle(1024,16525,true,true);
        require(LifecycleHook(payable(address(key.hooks))).calls()==0,"exhausted range rollback");
    }

    function equalRange(bytes32 slot,uint256 count) internal view returns(bytes32[] memory words) {
        words=IPoolManager(fe).extsload(slot,count);
        require(keccak256(abi.encode(words))==keccak256(abi.encode(sol.extsload(slot,count))),"accounting storage parity");
    }
    function assertPoolAccounting(PoolKey memory k,uint128[4] memory model,uint256 index) internal view {
        uint256 root=uint256(keccak256(abi.encode(k.toId(),uint256(6))));
        bytes32[] memory header=equalRange(bytes32(root),4);
        int24 tick=int24(uint24(uint256(header[0])>>160));
        uint256 active;uint256 negativeBits;uint256 positiveBits;
        for(uint256 range;range<2;range++) {
            int24 lower=range==0?int24(-120):int24(-600);int24 upper=-lower;
            uint128 amount=model[index*2+range];
            bytes32 position=keccak256(abi.encodePacked(address(actor),lower,upper,bytes32(range)));
            bytes32 slot=keccak256(abi.encode(position,root+6));
            require(uint128(uint256(equalRange(slot,3)[0]))==amount,"independent position liquidity");
            for(uint256 side;side<2;side++) {
                int24 bound=side==0?lower:upper;
                bytes32[] memory words=equalRange(keccak256(abi.encode(int256(bound),root+4)),3);
                require(uint128(uint256(words[0]))==amount,"independent tick gross");
                require(int128(uint128(uint256(words[0])>>128))==(side==0?int128(amount):-int128(amount)),"independent tick net");
            }
            if(amount>0) {
                negativeBits|=uint256(1)<<uint8(uint24(lower/k.tickSpacing));
                positiveBits|=uint256(1)<<uint8(uint24(upper/k.tickSpacing));
            }
            if(tick>=lower&&tick<upper)active+=amount;
        }
        require(uint128(uint256(header[3]))==active,"independent active liquidity");
        require(uint256(equalRange(keccak256(abi.encode(int256(-1),root+5)),1)[0])==negativeBits,"negative bitmap model");
        require(uint256(equalRange(keccak256(abi.encode(int256(0),root+5)),1)[0])==positiveBits,"positive bitmap model");
    }
    function testFuzz_statefulPoolAccounting(uint256 seed) public {
        PoolKey[2] memory keys;keys[0]=key;keys[1]=key;keys[1].fee=500;keys[1].tickSpacing=10;
        for(uint256 pool;pool<2;pool++){key=keys[pool];initialize();}
        uint128[4] memory model;
        for(uint256 step;step<20;step++) {
            seed=uint256(keccak256(abi.encode(seed,step)));
            uint256 pool=step<4?step/2:seed%2;uint256 range=step<4?step%2:(seed>>8)%2;
            uint256 choice=step<4?0:(seed>>16)%6;key=keys[pool];
            uint256 position=pool*2+range;int24 lower=range==0?int24(-120):int24(-600);
            Action[] memory actions=new Action[](1);int256 change;
            if(choice<=2||choice==5) {
                change=choice==0?int256(1e9+(seed>>32)%1e10):choice==1?-int256(uint256((seed>>26)%2==0?model[position]:model[position]/2)):choice==5?-int256(uint256(model[position])+1):int256(0);
                actions[0].data=abi.encodeCall(sol.modifyLiquidity,(key,ModifyLiquidityParams(lower,-lower,change,bytes32(range)),bytes("sequence")));
            } else if(choice==3) {
                bool direction=(seed>>24)%2==0;
                int256 amount=int256(1+(seed>>32)%1e12);if((seed>>25)%2==0)amount=-amount;
                actions[0].data=abi.encodeCall(sol.swap,(key,SwapParams(direction,amount,direction?uint160(4295128740):uint160(1461446703485210103287273052203988822378723970341)),bytes("sequence")));
            } else actions[0].data=abi.encodeCall(sol.donate,(key,(seed>>32)%1000,(seed>>48)%1000,bytes("sequence")));
            (bool ok,)=run(actions,true,"");
            if(choice==5)require(!ok,"excess removal must roll back");
            if(ok&&(choice<=2||choice==5))model[position]=uint128(uint256(int256(uint256(model[position]))+change));
            for(uint256 checkedPool;checkedPool<2;checkedPool++)assertPoolAccounting(keys[checkedPool],model,checkedPool);
        }
    }

}
