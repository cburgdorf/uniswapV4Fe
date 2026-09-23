// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "./reference/src/types/PoolOperation.sol";
import {V4Router} from "./periphery/src/V4Router.sol";
import {IV4Router} from "./periphery/src/interfaces/IV4Router.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
import {ReentrancyLock} from "./periphery/src/base/ReentrancyLock.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function warp(uint256) external;
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
interface IRouter {
    function execute(bytes calldata) external payable;
    function unlockCallback(bytes calldata) external returns(bytes memory);
    function msgSender() external view returns(address);
}
contract WorkflowToken {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    address public reentryTarget;bool public observedLock;
    function configureReentry(address target) external {reentryTarget=target;observedLock=false;}
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function approve(address to,uint256 amount) external {allowance[msg.sender][to]=amount;}
    function transfer(address to,uint256 amount) external returns(bool) {_transfer(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool) {
        if(reentryTarget!=address(0)) {
            (bool ok,bytes memory out)=reentryTarget.call(abi.encodeCall(IRouter.execute,(abi.encode(bytes(""),new bytes[](0)))));
            require(!ok && bytes4(out)==ReentrancyLock.ContractLocked.selector,"router reentrancy guard");observedLock=true;
            require(IRouter(reentryTarget).msgSender()==from,"authenticated payer");
        }
        allowance[from][msg.sender]-=amount;_transfer(from,to,amount);return true;
    }
    function _transfer(address from,address to,uint256 amount) internal {balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
}
// The original pinned Permit2 is deployed from independently hash-verified
// solc 0.8.17 bytecode. Reentrancy is exercised by the underlying token.
interface WorkflowPermit2 {
    function approve(address token,address spender,uint160 amount,uint48 expiration) external;
    function transferFrom(address from,address to,uint160 amount,address token) external;
    function allowance(address owner,address token,address spender) external view returns(uint160,uint48,uint48);
}
contract SolidityWorkflowRouter is V4Router,ReentrancyLock {
    WorkflowPermit2 public immutable permit2;
    constructor(IPoolManager manager,WorkflowPermit2 permit_) V4Router(manager) {permit2=permit_;}
    receive() external payable {}
    function execute(bytes calldata data) external payable isNotLocked {_executeActions(data);}
    function msgSender() public view override returns(address) {return _getLocker();}
    function _pay(Currency currency,address payer,uint256 amount) internal override {
        if(payer==address(this))currency.transfer(address(poolManager),amount);
        else permit2.transferFrom(payer,address(poolManager),uint160(amount),Currency.unwrap(currency));
    }
}
contract LiquiditySeeder {
    IPoolManager manager;
    receive() external payable {}
    function seed(IPoolManager m,PoolKey memory key) external {
        manager=m;m.initialize(key,79228162514264337593543950336);m.unlock(abi.encode(key));
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender==address(manager),"manager only");PoolKey memory key=abi.decode(data,(PoolKey));
        manager.modifyLiquidity(key,ModifyLiquidityParams(-600,600,1e24,0),"");
        pay(key.currency0);pay(key.currency1);return "";
    }
    function pay(Currency currency) internal {
        int256 delta=int256(uint256(manager.exttload(keccak256(abi.encode(address(this),currency)))));
        if(delta<0) {
            manager.sync(currency);
            if(Currency.unwrap(currency)==address(0))manager.settle{value:uint256(-delta)}();
            else {WorkflowToken(Currency.unwrap(currency)).transfer(address(manager),uint256(-delta));manager.settle();}
        }
    }
}
contract RouterWorkflowsTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    WorkflowToken low;WorkflowToken high;WorkflowToken middle;WorkflowPermit2 permit2;LiquiditySeeder seeder;
    bytes managerCode;bytes routerCode;
    receive() external payable {}
    function setUp() public {
        WorkflowToken a=new WorkflowToken();WorkflowToken b=new WorkflowToken();
        (low,high)=address(a)<address(b)?(a,b):(b,a);
        middle=new WorkflowToken();
        if(address(middle)<address(low)){WorkflowToken t=low;low=middle;middle=t;}
        if(address(middle)>address(high)){WorkflowToken t=high;high=middle;middle=t;}
        permit2=WorkflowPermit2(deploy(vm.parseBytes(vm.readFile("permit2-bytecode.txt"))));seeder=new LiquiditySeeder();
        managerCode=vm.parseBytes(vm.readFile("manager-bytecode.txt"));routerCode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        low.mint(address(this),1e30);high.mint(address(this),1e30);
        low.mint(address(seeder),1e30);high.mint(address(seeder),1e30);middle.mint(address(seeder),1e30);
        low.approve(address(permit2),type(uint256).max);high.approve(address(permit2),type(uint256).max);
        vm.deal(address(this),1e30);vm.deal(address(seeder),1e30);
    }
    function deploy(bytes memory code) internal returns(address target) {
        assembly ("memory-safe") {target:=create(0,add(code,32),mload(code))}require(target.code.length>0,"Fe deploy");
    }
    function system(bool feManager,bool feRouter) internal returns(IPoolManager manager,IRouter router) {
        manager=feManager?IPoolManager(deploy(bytes.concat(managerCode,abi.encode(address(this))))):IPoolManager(address(new PoolManager(address(this))));
        router=feRouter?IRouter(deploy(bytes.concat(routerCode,abi.encode(manager,permit2)))):IRouter(address(new SolidityWorkflowRouter(manager,permit2)));
    }
    uint160 constant PAYMENT_ALLOWANCE=1e25;
    struct Case {uint128 amount;bool exactOut;bool native;bool selfPay;bool reject;bool reenter;bool multi;uint8 paymentMode;}
    function run(bool feManager,bool feRouter,Case memory c) internal returns(bytes32 digest) {
        (IPoolManager manager,IRouter router)=system(feManager,feRouter);
        Currency input=Currency.wrap(c.native?address(0):address(low));Currency output=Currency.wrap(address(high));
        PoolKey memory key=PoolKey(input,c.multi?Currency.wrap(address(middle)):output,3000,60,IHooks(address(0)));seeder.seed(manager,key);
        PoolKey memory second=PoolKey(Currency.wrap(address(middle)),output,3000,60,IHooks(address(0)));
        if(c.multi)seeder.seed(manager,second);
        if(c.selfPay){low.mint(address(router),1e24);vm.deal(address(router),1e24);}
        permit2.approve(address(low),address(router),c.paymentMode==3?0:PAYMENT_ALLOWANCE,c.paymentMode==4?1:type(uint48).max);
        low.configureReentry(c.reenter?address(router):address(0));
        uint256 payerBefore=low.balanceOf(address(this));
        bytes[] memory params=new bytes[](c.paymentMode==2?4:3);
        params[0]=abi.encode(IV4Router.ExactInputSingleParams(key,true,c.amount,(c.reject&&c.paymentMode==0)?(c.exactOut?0:type(uint128).max):(c.exactOut?type(uint128).max:0),0,""));
        if(c.multi) {
            PathKey[] memory path=new PathKey[](2);
            path[0]=PathKey(c.exactOut?input:Currency.wrap(address(middle)),3000,60,IHooks(address(0)),"");
            path[1]=PathKey(c.exactOut?Currency.wrap(address(middle)):output,3000,60,IHooks(address(0)),"");
            params[0]=abi.encode(IV4Router.ExactInputParams(c.exactOut?output:input,path,new uint256[](0),c.amount,(c.reject&&c.paymentMode==0)?(c.exactOut?0:type(uint128).max):(c.exactOut?type(uint128).max:0)));
        }
        params[1]=abi.encode(input,uint256(0),!c.selfPay);
        params[2]=abi.encode(output,address(1),uint256(0));
        if(c.paymentMode==1) {
            params[1]=abi.encode(input,c.reject?uint256(0):type(uint256).max);
            params[2]=abi.encode(output,uint256(0));
        } else if(c.paymentMode==2) {
            params[2]=abi.encode(output,address(1),c.reject?uint256(10001):uint256(5017));
            params[3]=abi.encode(output,address(1),uint256(0));
        }
        bytes memory actions=abi.encodePacked(uint8(c.exactOut?(c.multi?9:8):(c.multi?7:6)),uint8(c.paymentMode==1?12:11),uint8(c.paymentMode==1?15:c.paymentMode==2?16:14));
        if(c.paymentMode==2)actions=bytes.concat(actions,hex"0e");
        uint256 value=c.native&&!c.selfPay?uint256(c.amount)*3+3:0;
        vm.recordLogs();
        (bool ok,bytes memory out)=address(router).call{value:value}(abi.encodeCall(IRouter.execute,(abi.encode(actions,params))));
        Vm.Log[] memory logs=vm.getRecordedLogs();
        if(c.multi&&!c.exactOut&&c.amount<=2) {
            require(!ok && bytes4(out)==bytes4(keccak256("SwapAmountCannotBeZero()")),"tiny route rounds intermediate amount to zero");
        } else require(ok!=c.reject,"expected workflow status");
        if(c.paymentMode==3)require(keccak256(out)==keccak256(abi.encodeWithSignature("InsufficientAllowance(uint256)",uint256(0))),"Permit2 allowance error");
        if(c.paymentMode==4)require(keccak256(out)==keccak256(abi.encodeWithSignature("AllowanceExpired(uint256)",uint256(1))),"Permit2 expiry error");
        require(router.msgSender()==address(0),"locker reset");
        require(manager.exttload(LOCK)==0 && manager.exttload(COUNT)==0,"manager relocked and settled");
        require(manager.exttload(keccak256(abi.encode(address(router),input)))==0,"input debt cleared");
        require(manager.exttload(keccak256(abi.encode(address(router),output)))==0,"output credit cleared");
        if(c.reenter&&!c.native&&!c.selfPay&&!c.reject)require(low.observedLock(),"payment reentrancy tested");
        bytes32 poolRoot=keccak256(abi.encode(keccak256(abi.encode(key)),uint256(6)));
        bytes32 secondRoot=keccak256(abi.encode(keccak256(abi.encode(second)),uint256(6)));
        bytes32[] memory secondState=c.multi?manager.extsload(secondRoot,7):new bytes32[](0);
        require(manager.exttload(keccak256(abi.encode(address(router),address(middle))))==0,"intermediate credit cleared");
        digest=keccak256(abi.encode(ok,out,logs,manager.extsload(poolRoot,7),secondState,middle.balanceOf(address(manager)),
            low.balanceOf(address(this)),low.balanceOf(address(router)),low.balanceOf(address(manager)),
            high.balanceOf(address(this)),high.balanceOf(address(router)),high.balanceOf(address(manager)),
            address(this).balance,address(router).balance,address(manager).balance));
        (uint160 allowed,uint48 expiration,uint48 nonce)=permit2.allowance(address(this),address(low),address(router));
        require(allowed==(c.paymentMode==3?0:PAYMENT_ALLOWANCE)-(payerBefore-low.balanceOf(address(this))),"exact Permit2 allowance debit or rollback");
        require(expiration==(c.paymentMode==4?1:type(uint48).max) && nonce==0,"Permit2 allowance metadata");
        digest=keccak256(abi.encode(digest,allowed,expiration,nonce,low.observedLock()));
    }
    function compare(Case memory c) internal {
        uint256 snap=vm.snapshotState();bytes32 baseline=run(false,false,c);require(vm.revertToState(snap),"restore baseline");
        snap=vm.snapshotState();bytes32 mixed=run(false,true,c);require(mixed==baseline,"Fe router / Solidity manager parity");require(vm.revertToState(snap),"restore mixed");
        bytes32 combined=run(true,true,c);require(combined==baseline,"Fe router / Fe manager parity");
    }
    function testFuzz_singleWorkflow(uint64 amount,bool exactOut,bool native,bool selfPay) public {
        compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,selfPay,false,false,false,0));
    }
    function testFuzz_multiWorkflow(uint64 amount,bool exactOut,bool native,bool selfPay) public {
        compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,selfPay,false,false,true,0));
    }
    function testFuzz_rollback(uint64 amount,bool exactOut,bool native) public {
        compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,false,true,false,false,0));
    }
    function test_permit2RejectionsRollBackSwap() public {
        vm.warp(100);
        compare(Case(1e15,false,false,false,true,false,false,3));
        compare(Case(1e15,false,false,false,true,false,true,4));
    }
    function test_reentrantPayment() public {compare(Case(1e15,false,false,false,false,true,false,0));}
    function testFuzz_allAndPortionActions(uint64 amount,bool native,bool reject,bool portion) public {
        compare(Case(uint128(uint256(amount)%1e18+1),false,native,false,reject,false,false,portion?2:1));
    }
    function test_tinyIntermediateAmounts() public {
        for(uint128 amount=1;amount<=3;amount++)compare(Case(amount,false,true,false,false,false,true,0));
    }
    function test_callbackAuthorizationAndEmptyBatch() public {
        for(uint256 i;i<2;i++) {
            (IPoolManager manager,IRouter router)=system(false,i==1);
            (bool ok,bytes memory out)=address(router).call(abi.encodeCall(IRouter.unlockCallback,(bytes(""))));
            require(!ok && bytes4(out)==bytes4(keccak256("NotPoolManager()")),"callback authorization");
            router.execute(abi.encode(bytes(""),new bytes[](0)));require(router.msgSender()==address(0),"empty batch clears lock");
            bytes[] memory p=new bytes[](1);p[0]="";
            (ok,out)=address(router).call(abi.encodeCall(IRouter.execute,(abi.encode(bytes(""),p))));
            require(!ok && bytes4(out)==bytes4(keccak256("InputLengthMismatch()")),"length mismatch");
            require(manager.exttload(LOCK)==0 && router.msgSender()==address(0),"rejected batch clears locks");
        }
    }
}
