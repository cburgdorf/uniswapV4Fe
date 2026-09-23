// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ProtocolFees} from "./reference/src/ProtocolFees.sol";
import {Pool} from "./reference/src/libraries/Pool.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {CurrencyReserves} from "./reference/src/libraries/CurrencyReserves.sol";
import {Lock} from "./reference/src/libraries/Lock.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
    function prank(address) external;
    function load(address,bytes32) external view returns(bytes32);
    function store(address,bytes32,bytes32) external;
    function deal(address,uint256) external;
}
contract SolidityProtocolFeesHarness is ProtocolFees {
    using Pool for Pool.State;
    mapping(PoolId=>Pool.State) pools;
    constructor(address initialOwner) ProtocolFees(initialOwner) {}
    function _getPool(PoolId id) internal override view returns(Pool.State storage) { return pools[id]; }
    function _isUnlocked() internal override view returns(bool) { return Lock.isUnlocked(); }
    function initializePool(PoolKey memory key) external { pools[key.toId()].initialize(1<<96,key.fee); }
    function accrue(Currency currency,uint256 amount) external { _updateProtocolFees(currency,amount); }
    function sync(Currency currency) external { CurrencyReserves.syncCurrencyAndReserves(currency,0); }
    function setUnlocked(bool value) external { if(value) Lock.unlock(); else Lock.lock(); }
}
interface AccruedReader { function protocolFeesAccrued(address) external view returns(uint256); }
contract FeeToken {
    bool public fail;
    uint256 public calls;
    uint256 public total;
    address public lastTo;
    uint256 expectedRemaining;
    function configure(bool value,uint256 expected) external { fail=value; expectedRemaining=expected; }
    function transfer(address to,uint256 amount) external returns(bool) {
        require(AccruedReader(msg.sender).protocolFeesAccrued(address(this))==expectedRemaining,"debit before transfer");
        calls++; unchecked { total+=amount; } lastTo=to;
        if(fail) revert("TOKEN_FAILURE");
        return true;
    }
}
contract FeeRecipient {
    bool public fail;
    uint256 public calls;
    function configure(bool value) external { fail=value; }
    receive() external payable { calls++; require(!fail,"NATIVE_FAILURE"); }
}
contract ProtocolFeesParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityProtocolFeesHarness sol;
    FeeToken token;
    FeeRecipient recipient;
    address constant OWNER=address(0x10001);
    address constant CONTROLLER=address(0x10002);
    address constant OUTSIDER=address(0x10003);
    function setUp() public {
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(OWNER));
        address deployed; assembly ("memory-safe") { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"Fe deploy");fe=deployed;
        sol=new SolidityProtocolFeesHarness(OWNER);token=new FeeToken();recipient=new FeeRecipient();
        compare(OWNER,abi.encodeCall(sol.setProtocolFeeController,(CONTROLLER)));
    }
    function compare(address caller,bytes memory data) internal returns(bool ok,bytes memory out) {
        vm.recordLogs();vm.prank(caller);(ok,out)=fe.call(data);Vm.Log[] memory a=vm.getRecordedLogs();
        vm.recordLogs();vm.prank(caller);(bool other,bytes memory expected)=address(sol).call(data);Vm.Log[] memory b=vm.getRecordedLogs();
        require(ok==other,"success mismatch"); require(keccak256(out)==keccak256(expected),"return/revert mismatch");
        require(a.length==b.length,"event count");
        for(uint256 i;i<a.length;i++) {
            require(a[i].emitter==fe && b[i].emitter==address(sol),"event emitter");
            require(keccak256(abi.encode(a[i].topics,a[i].data))==keccak256(abi.encode(b[i].topics,b[i].data)),"event fields");
        }
        require(vm.load(fe,0)==vm.load(address(sol),0),"owner slot");
        require(vm.load(fe,bytes32(uint256(2)))==vm.load(address(sol),bytes32(uint256(2))),"controller slot");
    }
    function checkAccrued(address currency,uint256 value) internal view {
        bytes32 slot=keccak256(abi.encode(currency,uint256(1)));
        require(vm.load(fe,slot)==bytes32(value) && vm.load(address(sol),slot)==bytes32(value),"accrued slot");
        (bool ok,bytes memory out)=fe.staticcall(abi.encodeCall(sol.protocolFeesAccrued,(Currency.wrap(currency))));
        require(ok && abi.decode(out,(uint256))==value,"accrued static getter");
    }
    function testFuzz_controller(address next,uint96 reserved,bool authorized) public {
        bytes32 word=bytes32((uint256(reserved)<<160)|uint160(CONTROLLER));
        vm.store(fe,bytes32(uint256(2)),word);vm.store(address(sol),bytes32(uint256(2)),word);
        (bool ok,bytes memory out)=compare(authorized?OWNER:OUTSIDER,abi.encodeCall(sol.setProtocolFeeController,(next)));
        require(ok==authorized,"onlyOwner");
        if(!ok) require(keccak256(out)==keccak256(abi.encodeWithSignature("Error(string)","UNAUTHORIZED")),"owner error");
        address expected=authorized?next:CONTROLLER;
        require(uint256(vm.load(fe,bytes32(uint256(2))))==((uint256(reserved)<<160)|uint160(expected)),"packed controller preservation");
        (ok,out)=fe.staticcall(abi.encodeCall(sol.protocolFeeController,()));require(ok && abi.decode(out,(address))==expected,"controller static getter");
    }
    function testFuzz_poolFee(uint24 fee,int24 spacing,bytes32 salt,bool initialized,bool authorized) public {
        PoolKey memory key=PoolKey(Currency.wrap(address(uint160(uint256(salt)))),Currency.wrap(address(2)),3000,spacing,IHooks(address(0)));
        if(initialized) { (bool created,)=compare(OUTSIDER,abi.encodeCall(sol.initializePool,(key))); require(created,"initialize"); }
        bytes32 slot=keccak256(abi.encode(key.toId(),uint256(3)));
        bytes32 before=vm.load(fe,slot);
        (bool ok,bytes memory out)=compare(authorized?CONTROLLER:OWNER,abi.encodeCall(sol.setProtocolFee,(key,fee)));
        bool valid=(fee&0xfff)<=1000 && (fee>>12)<=1000;
        require(ok==(authorized && valid && initialized),"fee acceptance model");
        if(!authorized)require(bytes4(out)==bytes4(keccak256("InvalidCaller()")),"caller precedence");
        else if(!valid)require(keccak256(out)==keccak256(abi.encodeWithSignature("ProtocolFeeTooLarge(uint24)",fee)),"fee precedence");
        else if(!initialized)require(bytes4(out)==bytes4(keccak256("PoolNotInitialized()")),"initialization error");
        require(vm.load(fe,slot)==vm.load(address(sol),slot),"pool slot parity");
        uint256 expected=ok?(uint256(before)&~(uint256(0xffffff)<<184))|(uint256(fee)<<184):uint256(before);
        require(uint256(vm.load(fe,slot))==expected,"pool field model");
    }
    function testFuzz_accrual(address currency,uint256 first,uint256 second) public {
        compare(OUTSIDER,abi.encodeCall(sol.accrue,(Currency.wrap(currency),first)));
        compare(OUTSIDER,abi.encodeCall(sol.accrue,(Currency.wrap(currency),second)));
        uint256 expected;unchecked {expected=first+second;}checkAccrued(currency,expected);
    }
    function testFuzz_collectToken(uint256 accrued,uint256 requested,uint8 mode,bool synced,bool unlocked,bool fail,bool authorized) public {
        address currency=address(token);uint256 amount=mode%3==0?0:mode%3==1?accrued:requested;
        compare(OUTSIDER,abi.encodeCall(sol.accrue,(Currency.wrap(currency),accrued)));
        compare(OUTSIDER,abi.encodeCall(sol.sync,(Currency.wrap(synced?currency:address(0)))));
        compare(OUTSIDER,abi.encodeCall(sol.setUnlocked,(unlocked)));
        uint256 collected=amount==0?accrued:amount;
        token.configure(fail,collected<=accrued?accrued-collected:0);
        (bool ok,bytes memory out)=compare(authorized?CONTROLLER:OWNER,abi.encodeCall(sol.collectProtocolFees,(address(recipient),Currency.wrap(currency),amount)));
        require(ok==(authorized && !synced && collected<=accrued && !fail),"token collect model");
        checkAccrued(currency,ok?accrued-collected:accrued);
        require(token.calls()==(ok?2:0),"token rollback");
        if(ok) { require(abi.decode(out,(uint256))==collected && token.lastTo()==address(recipient),"token result");uint256 total;unchecked {total=collected*2;}require(token.total()==total,"transferred total"); }
        else if(!authorized)require(bytes4(out)==bytes4(keccak256("InvalidCaller()")),"collect caller precedence");
        else if(synced)require(bytes4(out)==bytes4(keccak256("ProtocolFeeCurrencySynced()")),"sync precedence");
        else if(collected>accrued)require(keccak256(out)==keccak256(abi.encodeWithSignature("Panic(uint256)",0x11)),"underflow panic");
    }
    function testFuzz_collectNative(uint128 accrued,uint128 requested,uint128 balance,bool all,bool fail,bool unlocked) public {
        compare(OUTSIDER,abi.encodeCall(sol.accrue,(Currency.wrap(address(0)),accrued)));
        compare(OUTSIDER,abi.encodeCall(sol.sync,(Currency.wrap(address(0)))));
        compare(OUTSIDER,abi.encodeCall(sol.setUnlocked,(unlocked)));
        vm.deal(fe,balance);vm.deal(address(sol),balance);recipient.configure(fail);
        uint256 amount=all?0:requested;uint256 collected=amount==0?accrued:amount;
        (bool ok,bytes memory out)=compare(CONTROLLER,abi.encodeCall(sol.collectProtocolFees,(address(recipient),Currency.wrap(address(0)),amount)));
        require(ok==(collected<=accrued && collected<=balance && !fail),"native collect model");
        checkAccrued(address(0),ok?accrued-collected:accrued);
        require(fe.balance==address(sol).balance && fe.balance==(ok?balance-collected:balance),"native balance rollback");
        require(recipient.calls()==(ok?2:0) && address(recipient).balance==(ok?collected*2:0),"recipient effects");
        if(ok)require(abi.decode(out,(uint256))==collected,"native result");
    }
    function test_explicitBoundaries() public {
        testFuzz_poolFee(0,1,0,true,true);
        testFuzz_poolFee(uint24(1000|(1000<<12)),1,bytes32(uint256(1)),true,true);
        testFuzz_poolFee(1001,1,bytes32(uint256(2)),false,true);
        testFuzz_poolFee(uint24(1001<<12),1,bytes32(uint256(3)),true,true);
        testFuzz_accrual(address(7),type(uint256).max,1);
    }
    function test_otherSyncedCurrencyDoesNotBlock() public {
        compare(OUTSIDER,abi.encodeCall(sol.accrue,(Currency.wrap(address(token)),10)));
        compare(OUTSIDER,abi.encodeCall(sol.sync,(Currency.wrap(address(0x1234)))));
        token.configure(false,0);
        (bool ok,bytes memory out)=compare(CONTROLLER,abi.encodeCall(sol.collectProtocolFees,(address(recipient),Currency.wrap(address(token)),0)));
        require(ok && abi.decode(out,(uint256))==10,"other currency sync");checkAccrued(address(token),0);
    }
    function test_unlockedCollectionAndSyncedZero() public {
        testFuzz_collectToken(10,0,0,false,true,false,true);
        // Reset the token's accrued state; successful collection above removed all fees.
        (bool ok,)=compare(OUTSIDER,abi.encodeCall(sol.sync,(Currency.wrap(address(token)))));require(ok,"sync");
        (ok,)=compare(CONTROLLER,abi.encodeCall(sol.collectProtocolFees,(address(recipient),Currency.wrap(address(token)),0)));require(!ok,"synced zero collection blocked");
    }
}
