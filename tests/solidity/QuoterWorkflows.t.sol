// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {ModifyLiquidityParams} from "./reference/src/types/PoolOperation.sol";
import {V4Quoter} from "./periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "./periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract WorkflowToken {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function approve(address to,uint256 amount) external {allowance[msg.sender][to]=amount;}
    function transfer(address to,uint256 amount) external returns(bool) {_transfer(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool) {
        allowance[from][msg.sender]-=amount;_transfer(from,to,amount);return true;
    }
    function _transfer(address from,address to,uint256 amount) internal {balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
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

contract QuoterWorkflowsTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    WorkflowToken low;WorkflowToken middle;WorkflowToken high;LiquiditySeeder seeder;
    bytes managerCode;bytes quoterCode;
    function setUp() public {
        WorkflowToken a=new WorkflowToken();WorkflowToken b=new WorkflowToken();
        (low,high)=address(a)<address(b)?(a,b):(b,a);
        middle=new WorkflowToken();
        if(address(middle)<address(low)){WorkflowToken t=low;low=middle;middle=t;}
        if(address(middle)>address(high)){WorkflowToken t=high;high=middle;middle=t;}
        seeder=new LiquiditySeeder();
        managerCode=vm.parseBytes(vm.readFile("manager-bytecode.txt"));quoterCode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        low.mint(address(seeder),1e30);middle.mint(address(seeder),1e30);high.mint(address(seeder),1e30);
        vm.deal(address(seeder),1e30);
    }
    function deploy(bytes memory code) internal returns(address target) {
        assembly ("memory-safe") {target:=create(0,add(code,32),mload(code))}require(target.code.length>0,"Fe deploy");
    }
    struct Case {uint128 amount;bool exactOut;bool native;bool reverse;bool multi;bool uninitialized;}
    function state(IPoolManager manager,PoolKey memory first,PoolKey memory second,bool multi) internal view returns(bytes32) {
        bytes32 root=keccak256(abi.encode(keccak256(abi.encode(first)),uint256(6)));
        bytes32 other=keccak256(abi.encode(keccak256(abi.encode(second)),uint256(6)));
        return keccak256(abi.encode(manager.extsload(root,7),multi?manager.extsload(other,7):new bytes32[](0),
            low.balanceOf(address(manager)),middle.balanceOf(address(manager)),high.balanceOf(address(manager)),address(manager).balance));
    }
    function run(bool feManager,bool feQuoter,Case memory c) internal returns(bytes32) {
        IPoolManager manager=feManager?IPoolManager(deploy(bytes.concat(managerCode,abi.encode(address(this))))):IPoolManager(address(new PoolManager(address(this))));
        IV4Quoter quoter=feQuoter?IV4Quoter(deploy(bytes.concat(quoterCode,abi.encode(manager)))):IV4Quoter(address(new V4Quoter(manager)));
        Currency bottom=Currency.wrap(c.native?address(0):address(low));Currency top=Currency.wrap(address(high));Currency mid=Currency.wrap(address(middle));
        PoolKey memory first=PoolKey(bottom,c.multi?mid:top,3000,60,IHooks(address(0)));
        PoolKey memory second=PoolKey(mid,top,3000,60,IHooks(address(0)));
        if(!c.uninitialized){seeder.seed(manager,first);if(c.multi)seeder.seed(manager,second);}
        bytes memory data;
        if(!c.multi) {
            IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(first,!c.reverse,c.amount,"");
            data=c.exactOut?abi.encodeCall(quoter.quoteExactOutputSingle,(p)):abi.encodeCall(quoter.quoteExactInputSingle,(p));
        } else {
            Currency input=c.reverse?top:bottom;Currency output=c.reverse?bottom:top;
            PathKey[] memory path=new PathKey[](2);
            path[0]=PathKey(c.exactOut?input:mid,3000,60,IHooks(address(0)),"");
            path[1]=PathKey(c.exactOut?mid:output,3000,60,IHooks(address(0)),"");
            IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(c.exactOut?output:input,path,c.amount);
            data=c.exactOut?abi.encodeCall(quoter.quoteExactOutput,(p)):abi.encodeCall(quoter.quoteExactInput,(p));
        }
        bytes32 beforeState=state(manager,first,second,c.multi);
        (bool ok,bytes memory out)=address(quoter).call(data);
        require(state(manager,first,second,c.multi)==beforeState,"quote changed pool state or balances");
        require(quoter.msgSender()==address(0),"sender reset");
        require(manager.exttload(LOCK)==0&&manager.exttload(COUNT)==0,"manager transient reset");
        require(manager.exttload(keccak256(abi.encode(address(quoter),bottom)))==0,"bottom delta reset");
        require(manager.exttload(keccak256(abi.encode(address(quoter),mid)))==0,"middle delta reset");
        require(manager.exttload(keccak256(abi.encode(address(quoter),top)))==0,"top delta reset");
        if(ok){(uint256 amount,uint256 estimated)=abi.decode(out,(uint256,uint256));require(estimated>0,"gas estimate");out=abi.encode(amount);}
        if(c.uninitialized||c.amount==0||c.amount==1e30)require(!ok,"expected rejection");
        else if(!c.multi||c.exactOut||c.amount>2)require(ok,"expected filled quote");
        return keccak256(abi.encode(ok,out,beforeState));
    }
    function compare(Case memory c) internal {
        uint256 snap=vm.snapshotState();bytes32 baseline=run(false,false,c);require(vm.revertToState(snap),"restore baseline");
        snap=vm.snapshotState();require(run(false,true,c)==baseline,"Fe quoter / Solidity manager");require(vm.revertToState(snap),"restore mixed");
        require(run(true,true,c)==baseline,"Fe quoter / Fe manager");
    }
    function testFuzz_single(uint64 amount,bool exactOut,bool native,bool reverse) public {compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,reverse,false,false));}
    function testFuzz_multi(uint64 amount,bool exactOut,bool native,bool reverse) public {compare(Case(uint128(uint256(amount)%1e18+1),exactOut,native,reverse,true,false));}
    function test_rejectionsAndTinyAmounts() public {
        for(uint256 i;i<4;i++) {
            compare(Case(0,i%2==0,false,false,i>1,false));
            compare(Case(1,i%2==0,false,false,i>1,false));
            compare(Case(2,i%2==0,false,false,i>1,false));
            compare(Case(1e30,i%2==0,false,false,i>1,false));
            compare(Case(100,i%2==0,false,false,i>1,true));
        }
    }
}
