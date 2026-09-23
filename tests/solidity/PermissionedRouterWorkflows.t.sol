// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams,SwapParams} from "./reference/src/types/PoolOperation.sol";
import {BeforeSwapDelta,BeforeSwapDeltaLibrary} from "./reference/src/types/BeforeSwapDelta.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
import {IV4Router} from "./periphery/src/interfaces/IV4Router.sol";
import {PermissionedV4Router} from "./periphery/src/hooks/permissionedPools/PermissionedV4Router.sol";
import {PermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {IPermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPermissionsAdapter, IERC20} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {ReentrancyLock} from "./periphery/src/base/ReentrancyLock.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function etch(address,bytes calldata) external;
    function deal(address,uint256) external;
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
interface Router {
    function execute(bytes calldata) external payable;
    function unlockCallback(bytes calldata) external returns(bytes memory);
    function msgSender() external view returns(address);
    function poolManager() external view returns(address);
    function permit2() external view returns(address);
    function PERMISSIONS_ADAPTER_FACTORY() external view returns(address);
}
interface Permit2 {
    function approve(address,address,uint160,uint48) external;
    function transferFrom(address,address,uint160,address) external;
    function allowance(address,address,address) external view returns(uint160,uint48,uint48);
}
contract Asset {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    mapping(address=>bool) public denied;
    address public reentryTarget;bool public observedLock;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function approve(address spender,uint256 amount) external returns(bool) {allowance[msg.sender][spender]=amount;return true;}
    function deny(address who,bool value) external {denied[who]=value;}
    function reenter(address target) external {reentryTarget=target;observedLock=false;}
    function transfer(address to,uint256 amount) external returns(bool) {move(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool) {
        if(reentryTarget!=address(0)) {
            (bool ok,bytes memory out)=reentryTarget.call(abi.encodeCall(Router.execute,(abi.encode(bytes(""),new bytes[](0)))));
            require(!ok&&bytes4(out)==ReentrancyLock.ContractLocked.selector,"payment lock");observedLock=true;
        }
        if(allowance[from][msg.sender]!=type(uint256).max)allowance[from][msg.sender]-=amount;
        move(from,to,amount);return true;
    }
    function move(address from,address to,uint256 amount) internal {
        require(!denied[to],"issuer transfer restriction");balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);
    }
}
contract Allowlist is IAllowlistChecker {
    PermissionFlag public flags=PermissionFlag.wrap(0xffff);
    address public account;
    constructor(address who) {account=who;}
    function set(bytes2 f) external {flags=PermissionFlag.wrap(f);}
    function supportsInterface(bytes4 id) external pure returns(bool) {return id==0x01ffc9a7||id==type(IAllowlistChecker).interfaceId;}
    function checkAllowlist(address who,address) external view returns(PermissionFlag) {
        return who==account?flags:PermissionFlag.wrap(0);
    }
}
contract GuardHook {
    IPoolManager immutable manager;IPermissionsAdapterFactory immutable factory;
    uint256 public calls;
    error Unauthorized();
    constructor(IPoolManager m,IPermissionsAdapterFactory f) {manager=m;factory=f;}
    function beforeSwap(address sender,PoolKey calldata key,SwapParams calldata,bytes calldata) external returns(bytes4,BeforeSwapDelta,uint24) {
        require(msg.sender==address(manager));address user=Router(sender).msgSender();
        address[2] memory currencies=[Currency.unwrap(key.currency0),Currency.unwrap(key.currency1)];
        for(uint256 i;i<2;++i)if(factory.verifiedPermissionsAdapterOf(currencies[i])!=address(0)) {
            if(!IPermissionsAdapter(currencies[i]).isAllowed(user,PermissionFlag.wrap(0x0001)))revert Unauthorized();
        }
        calls++;return(IHooks.beforeSwap.selector,BeforeSwapDeltaLibrary.ZERO_DELTA,0);
    }
}
contract SolidityPermissionedRouter is PermissionedV4Router,ReentrancyLock {
    Permit2 public immutable permit2;
    constructor(IPoolManager m,Permit2 p,IPermissionsAdapterFactory f) PermissionedV4Router(m,f) {permit2=p;}
    receive() external payable {}
    function execute(bytes calldata data) external payable isNotLocked {_executeActions(data);}
    function msgSender() public view override returns(address) {return _getLocker();}
    function _payStandard(Currency c,address payer,uint256 amount) internal override {
        if(payer==address(this))c.transfer(address(poolManager),amount);
        else permit2.transferFrom(payer,address(poolManager),uint160(amount),Currency.unwrap(c));
    }
    function _payPermissionedFromPayer(address payer,IPermissionsAdapter adapter,address token,uint256 amount) internal override {
        permit2.transferFrom(payer,address(adapter),uint160(amount),token);adapter.wrapToPoolManager(amount);
    }
}
contract Seeder {
    IPoolManager manager;IPermissionsAdapterFactory factory;
    receive() external payable {}
    function seed(IPoolManager m,IPermissionsAdapterFactory f,PoolKey memory key) external {
        manager=m;factory=f;m.initialize(key,79228162514264337593543950336);m.unlock(abi.encode(key));
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender==address(manager));PoolKey memory key=abi.decode(data,(PoolKey));
        manager.modifyLiquidity(key,ModifyLiquidityParams(-600,600,1e24,0),"");pay(key.currency0);pay(key.currency1);return "";
    }
    function pay(Currency currency) internal {
        int256 delta=int256(uint256(manager.exttload(keccak256(abi.encode(address(this),currency)))));
        if(delta>=0)return;uint256 amount=uint256(-delta);manager.sync(currency);
        address token=factory.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
        if(Currency.unwrap(currency)==address(0))manager.settle{value:amount}();
        else {
            if(token==address(0))Asset(Currency.unwrap(currency)).transfer(address(manager),amount);
            else {Asset(token).transfer(Currency.unwrap(currency),amount);IPermissionsAdapter(Currency.unwrap(currency)).wrapToPoolManager(amount);}
            manager.settle();
        }
    }
}
contract PermissionedRouterWorkflowsTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant HOOK=address(0x10080); // Only BEFORE_SWAP_FLAG is set.
    bytes32 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    Asset a;Asset b;Asset middle;Allowlist checker;Seeder seeder;Permit2 permit;
    bytes managerCode;bytes routerCode;bytes factoryCode;
    receive() external payable {}
    function deploy(bytes memory code) internal returns(address addr) {
        assembly ("memory-safe") {addr:=create(0,add(code,32),mload(code))}require(addr.code.length>0,"Fe deploy");
    }
    function setUp() public {
        a=new Asset();b=new Asset();middle=new Asset();checker=new Allowlist(address(this));seeder=new Seeder();
        managerCode=vm.parseBytes(vm.readFile("manager-bytecode.txt"));routerCode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));factoryCode=vm.parseBytes(vm.readFile("permissions-factory-bytecode.txt"));
        permit=Permit2(deploy(vm.parseBytes(vm.readFile("permit2-bytecode.txt"))));
        a.mint(address(this),1e30);b.mint(address(this),1e30);a.mint(address(seeder),1e30);b.mint(address(seeder),1e30);middle.mint(address(seeder),1e30);
        a.approve(address(permit),type(uint256).max);b.approve(address(permit),type(uint256).max);
        vm.deal(address(this),1e30);vm.deal(address(seeder),1e30);
    }
    struct System {IPoolManager manager;IPermissionsAdapterFactory factory;Router router;address adapterA;address adapterB;PoolKey key;PoolKey second;Currency input;Currency output;}
    struct Case {uint128 amount;bool exactOut;bool native;bool selfPay;bool contractBalance;bool plain;bool disabledFactory;uint8 reject;bool reenter;uint8 takeMode;bool multi;}
    function system(bool feManager,bool feRouter,bool feFactory,Case memory c) internal returns(System memory s) {
        s.manager=feManager?IPoolManager(deploy(bytes.concat(managerCode,abi.encode(address(this))))):IPoolManager(address(new PoolManager(address(this))));
        s.factory=feFactory?IPermissionsAdapterFactory(deploy(bytes.concat(factoryCode,abi.encode(s.manager)))):IPermissionsAdapterFactory(address(new PermissionsAdapterFactory(address(s.manager))));
        address factoryArg=c.disabledFactory?address(0):address(s.factory);
        s.router=feRouter?Router(deploy(bytes.concat(routerCode,abi.encode(s.manager,permit,factoryArg)))):Router(address(new SolidityPermissionedRouter(s.manager,permit,IPermissionsAdapterFactory(factoryArg))));
        s.adapterA=s.factory.createPermissionsAdapter(IERC20(address(a)),address(this),checker);
        s.adapterB=s.factory.createPermissionsAdapter(IERC20(address(b)),address(this),checker);
        a.mint(s.adapterA,1);b.mint(s.adapterB,1);s.factory.verifyPermissionsAdapter(s.adapterA);s.factory.verifyPermissionsAdapter(s.adapterB);
        address[2] memory adapters=[s.adapterA,s.adapterB];
        for(uint256 i;i<2;++i) {
            IPermissionsAdapter adapter=IPermissionsAdapter(adapters[i]);
            adapter.updateAllowedWrapper(address(seeder),true);adapter.updateAllowedWrapper(address(s.router),true);
            adapter.updateAllowedHook(IHooks(HOOK),true);adapter.updateSwappingEnabled(true);
        }
        permit.approve(address(a),address(s.router),type(uint160).max,type(uint48).max);
        permit.approve(address(b),address(s.router),type(uint160).max,type(uint48).max);
        address left=c.native?address(0):c.plain?address(a):s.adapterA;
        address right=c.plain?address(b):s.adapterB;
        if(left>right)(left,right)=(right,left);
        s.input=Currency.wrap(left);s.output=Currency.wrap(right);
        s.key=poolKey(s.input,c.multi?Currency.wrap(address(middle)):s.output);
        s.second=poolKey(Currency.wrap(address(middle)),s.output);
        vm.etch(HOOK,address(new GuardHook(s.manager,s.factory)).code);
        seeder.seed(s.manager,s.factory,s.key);
        if(c.multi)seeder.seed(s.manager,s.factory,s.second);
    }
    function poolKey(Currency left,Currency right) internal pure returns(PoolKey memory) {
        if(Currency.unwrap(left)>Currency.unwrap(right))(left,right)=(right,left);
        return PoolKey(left,right,3000,60,IHooks(HOOK));
    }
    function run(bool feManager,bool feRouter,bool feFactory,Case memory c) internal returns(bytes32 digest) {
        System memory s=system(feManager,feRouter,feFactory,c);
        Currency input=s.input;Currency output=s.output;
        if(c.selfPay) {a.mint(address(s.router),1e24);b.mint(address(s.router),1e24);vm.deal(address(s.router),1e24);}
        if(c.reject==1)IPermissionsAdapter(Currency.unwrap(output)).updateSwappingEnabled(false);
        if(c.reject==2)checker.set(0);
        if(c.reject==3)IPermissionsAdapter(Currency.unwrap(output)).updateAllowedHook(IHooks(HOOK),false);
        if(c.reject==4) {a.deny(address(this),true);b.deny(address(this),true);}
        if(c.reenter) {a.reenter(address(s.router));b.reenter(address(s.router));}
        bool refund=c.contractBalance&&c.selfPay;
        uint256 count=3+(refund?1:0)+(c.takeMode==2?1:0);
        bytes[] memory params=new bytes[](count);
        params[0]=abi.encode(IV4Router.ExactInputSingleParams(s.key,true,c.amount,c.exactOut?type(uint128).max:0,0,""));
        if(c.multi) {
            PathKey[] memory path=new PathKey[](2);
            path[0]=PathKey(c.exactOut?input:Currency.wrap(address(middle)),3000,60,IHooks(HOOK),"");
            path[1]=PathKey(c.exactOut?Currency.wrap(address(middle)):output,3000,60,IHooks(HOOK),"");
            params[0]=abi.encode(IV4Router.ExactInputParams(c.exactOut?output:input,path,new uint256[](0),c.amount,c.exactOut?type(uint128).max:0));
        }
        params[1]=c.takeMode==1?abi.encode(input,type(uint256).max):abi.encode(input,refund?uint256(1)<<255:0,!c.selfPay);
        params[2]=c.takeMode==1?abi.encode(output,uint256(0)):abi.encode(output,address(1),c.takeMode==2?uint256(5017):0);
        bytes memory actions=abi.encodePacked(uint8(c.exactOut?(c.multi?9:8):(c.multi?7:6)),uint8(c.takeMode==1?12:11),uint8(c.takeMode==1?15:c.takeMode==2?16:14));
        uint256 cursor=3;
        if(c.takeMode==2) {params[cursor++]=abi.encode(output,address(1),uint256(0));actions=bytes.concat(actions,hex"0e");}
        if(refund) {params[cursor]=abi.encode(input,address(1),uint256(0));actions=bytes.concat(actions,hex"0e");}
        uint256 value=c.native&&!c.selfPay?uint256(c.amount)*3+3:0;
        address outputToken=s.factory.verifiedPermissionsAdapterOf(Currency.unwrap(output));
        if(outputToken==address(0))outputToken=Currency.unwrap(output);
        uint256 outputBefore=Asset(outputToken).balanceOf(address(this));
        uint256 hookCalls=GuardHook(HOOK).calls();
        vm.recordLogs();(bool ok,bytes memory out)=address(s.router).call{value:value}(abi.encodeCall(Router.execute,(abi.encode(actions,params))));
        Vm.Log[] memory logs=vm.getRecordedLogs();
        bool tiny=c.multi&&!c.exactOut&&c.amount<=2;
        if(c.reject==4) {
            // Zero credit short-circuits TAKE, so a denied recipient need not be called.
            require(!ok||Asset(outputToken).balanceOf(address(this))==outputBefore,"denied recipient received tokens");
        } else require(ok==(c.reject==0&&!tiny),"workflow status");
        if(tiny)require(bytes4(out)==bytes4(keccak256("SwapAmountCannotBeZero()")),"tiny route reason");
        require(GuardHook(HOOK).calls()-hookCalls==(ok?(c.multi?2:1):0),"hook execution/rollback");
        require(s.router.msgSender()==address(0),"router unlocked");
        require(s.manager.exttload(LOCK)==0&&s.manager.exttload(COUNT)==0,"manager settled");
        require(s.manager.exttload(keccak256(abi.encode(address(s.router),input)))==0,"input cleared");
        require(s.manager.exttload(keccak256(abi.encode(address(s.router),output)))==0,"output cleared");
        if(c.reenter&&!c.native&&!c.selfPay&&c.reject==0)require(a.observedLock()||b.observedLock(),"real Permit2 reentry observed");
        bytes32 root=keccak256(abi.encode(keccak256(abi.encode(s.key)),uint256(6)));
        bytes32 secondRoot=keccak256(abi.encode(keccak256(abi.encode(s.second)),uint256(6)));
        bytes32[] memory secondState=c.multi?s.manager.extsload(secondRoot,7):new bytes32[](0);
        require(s.manager.exttload(keccak256(abi.encode(address(s.router),address(middle))))==0,"intermediate cleared");
        digest=keccak256(abi.encode(ok,out,logs,secondState,middle.balanceOf(address(s.manager)),s.manager.extsload(root,7),GuardHook(HOOK).calls(),address(this).balance,address(s.router).balance,address(s.manager).balance));
        address[5] memory accounts=[address(this),address(s.router),address(s.manager),s.adapterA,s.adapterB];
        for(uint256 i;i<5;++i)digest=keccak256(abi.encode(digest,a.balanceOf(accounts[i]),b.balanceOf(accounts[i])));
        address[2] memory adapters=[s.adapterA,s.adapterB];
        for(uint256 i;i<2;++i) {
            IPermissionsAdapter adapter=IPermissionsAdapter(adapters[i]);uint256 supply=adapter.totalSupply();
            require(adapter.balanceOf(address(s.manager))==supply,"sole holder");
            require(Asset(address(adapter.PERMISSIONED_TOKEN())).balanceOf(adapters[i])>=supply,"backed");
            digest=keccak256(abi.encode(digest,supply,adapter.balanceOf(address(this)),adapter.balanceOf(address(s.router))));
        }
        (uint160 allowanceA,uint48 expirationA,uint48 nonceA)=permit.allowance(address(this),address(a),address(s.router));
        (uint160 allowanceB,uint48 expirationB,uint48 nonceB)=permit.allowance(address(this),address(b),address(s.router));
        digest=keccak256(abi.encode(digest,allowanceA,expirationA,nonceA,allowanceB,expirationB,nonceB,a.observedLock(),b.observedLock()));
    }
    function compare(Case memory c) internal {
        uint256 snap=vm.snapshotState();bytes32 baseline=run(false,false,false,c);require(vm.revertToState(snap));
        snap=vm.snapshotState();require(run(false,true,false,c)==baseline,"Fe router");require(vm.revertToState(snap));
        snap=vm.snapshotState();require(run(false,true,true,c)==baseline,"Fe router/factory");require(vm.revertToState(snap));
        require(run(true,true,true,c)==baseline,"Fe full system");
    }
    function testFuzz_swaps(uint64 amount,bool exactOut,bool native,bool selfPay,bool refund) public {
        compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,selfPay,refund,false,false,0,false,0,false));
    }
    function testFuzz_rollback(uint64 amount,uint8 reason,bool exactOut,bool native) public {
        compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,false,false,false,false,1+reason%4,false,0,false));
    }
    function testFuzz_takeActions(uint64 amount,bool native,bool portion) public {
        compare(Case(uint128(uint256(amount)%1e18+1),false,native,false,false,false,false,0,false,portion?2:1,false));
    }
    function testFuzz_multihop(uint64 amount,bool exactOut,bool native,bool selfPay) public {
        compare(Case(uint128(uint256(amount)%1e18+10),exactOut,native,selfPay,false,false,false,0,false,0,true));
    }
    function test_zeroOutputDoesNotCallBlockedRecipient() public {
        compare(Case(1,false,false,false,false,false,false,4,false,0,false));
        compare(Case(1,false,true,false,false,false,false,4,false,0,false));
    }
    function test_tinyMultihop() public {
        for(uint128 amount=1;amount<=3;++amount)compare(Case(amount,false,true,false,false,false,false,0,false,0,true));
    }
    function test_callbackAndEntryBoundaries() public {
        for(uint256 i;i<2;++i) {
            Case memory c;
            System memory s=system(false,i==1,i==1,c);
            require(s.router.poolManager()==address(s.manager)&&s.router.permit2()==address(permit)&&s.router.PERMISSIONS_ADAPTER_FACTORY()==address(s.factory),"configuration getters");
            (bool ok,bytes memory out)=address(s.router).call(abi.encodeCall(Router.unlockCallback,(bytes(""))));
            require(!ok&&bytes4(out)==bytes4(keccak256("NotPoolManager()")),"callback authorization");
            s.router.execute(abi.encode(bytes(""),new bytes[](0)));
            require(s.router.msgSender()==address(0),"empty unlock");
            bytes[] memory wrong=new bytes[](1);
            (ok,out)=address(s.router).call(abi.encodeCall(Router.execute,(abi.encode(bytes(""),wrong))));
            require(!ok&&bytes4(out)==bytes4(keccak256("InputLengthMismatch()")),"batch shape");
            (ok,)=address(s.router).call{value:1}(hex"");require(ok,"receive");
            (ok,)=address(s.router).call(hex"12345678");require(!ok,"unknown selector");
        }
    }
    function test_plainAndDisabledFactory() public {
        compare(Case(1e15,false,false,false,false,true,false,0,false,0,false));
        compare(Case(1e15,true,true,true,true,true,true,0,false,0,false));
    }
    function test_realPermit2Reentry() public {compare(Case(1e15,false,false,false,false,false,false,0,true,0,false));}
}
