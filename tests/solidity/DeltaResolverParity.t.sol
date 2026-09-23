// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {DeltaResolver} from "./periphery/src/base/DeltaResolver.sol";
import {ImmutableState} from "./periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "./reference/src/libraries/TransientStateLibrary.sol";
import {Currency} from "./reference/src/types/Currency.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function expectCall(address,bytes calldata,uint64) external;
}
contract ResolverReference is DeltaResolver {
    using TransientStateLibrary for IPoolManager;
    constructor(IPoolManager m) ImmutableState(m) {}
    function _pay(Currency,address,uint256) internal override {revert("not exposed");}
    function read(address target,Currency currency,uint8 mode) external view returns(uint256) {
        if(mode==0) return uint160(Currency.unwrap(poolManager.getSyncedCurrency()));
        if(mode==1) return poolManager.getSyncedReserves();
        if(mode==2) return poolManager.getNonzeroDeltaCount();
        if(mode==3) return uint256(poolManager.currencyDelta(target,currency));
        return poolManager.isUnlocked()?1:0;
    }
    function amount(Currency currency,Currency input,uint256 value,uint8 mode) external view returns(uint256) {
        if(mode==0) return _getFullDebt(currency);
        if(mode==1) return _getFullCredit(currency);
        if(mode==2) return _mapSettleAmount(value,currency);
        if(mode==3) return _mapTakeAmount(value,currency);
        return _mapWrapUnwrapAmount(input,value,currency);
    }
}
contract ResolverProvider {
    mapping(bytes32=>bytes32) words;
    bool raw;bool reject;bytes response;
    function set(bytes32 slot,bytes32 value) external {words[slot]=value;}
    function configure(bool raw_,bool reject_,bytes memory data) external {raw=raw_;reject=reject_;response=data;}
    function exttload(bytes32 slot) external view returns(bytes32) {
        if(raw) {bytes memory b=response;bool r=reject;assembly {if r {revert(add(b,32),mload(b))} return(add(b,32),mload(b))}}
        return words[slot];
    }
}
contract ResolverToken {
    uint256 public value;
    function set(uint256 v) external {value=v;}
    function balanceOf(address) external view returns(uint256) {return value;}
}
contract DeltaResolverParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant CURRENCY=0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;
    bytes32 constant RESERVES=0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    bytes32 constant UNLOCKED=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    address fe;ResolverReference sol;ResolverProvider manager;ResolverToken token;
    function setUp() public {
        manager=new ResolverProvider();token=new ResolverToken();
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(manager)));
        address deployed;assembly {deployed:=create(0,add(code,32),mload(code))}
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new ResolverReference(IPoolManager(address(manager)));
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall(data);(bool other,bytes memory expected)=address(sol).staticcall(data);
        require(ok==other,"resolver status mismatch");require(keccak256(out)==keccak256(expected),"resolver bytes mismatch");
    }
    function setDelta(address account,address currency,int256 value) internal {
        manager.set(keccak256(abi.encode(account,currency)),bytes32(uint256(value)));
    }
    function testFuzz_reads(address target,address currency,uint256 synced,uint256 reserves,uint256 count,int256 delta,uint256 unlocked) public {
        manager.set(CURRENCY,bytes32(synced));manager.set(RESERVES,bytes32(reserves));manager.set(COUNT,bytes32(count));manager.set(UNLOCKED,bytes32(unlocked));setDelta(target,currency,delta);
        for(uint8 i;i<5;i++) {
            (bool ok,bytes memory out)=compare(abi.encodeCall(sol.read,(target,Currency.wrap(currency),i)));require(ok,"read");
            uint256 expected=i==0?uint160(synced):i==1?(uint160(synced)==0?0:reserves):i==2?count:i==3?uint256(delta):unlocked==0?0:1;
            require(abi.decode(out,(uint256))==expected,"independent read model");
        }
        vm.expectCall(address(manager),abi.encodeWithSignature("exttload(bytes32)",keccak256(abi.encode(target,currency))),2);
        compare(abi.encodeCall(sol.read,(target,Currency.wrap(currency),uint8(3))));
    }
    function testFuzz_amounts(int256 delta,uint256 balance,uint256 value,bool native,uint8 choose) public {
        address currency=native?address(0):address(token);
        setDelta(fe,currency,delta);setDelta(address(sol),currency,delta);
        token.set(balance);vm.deal(fe,balance);vm.deal(address(sol),balance);
        uint256 selected=choose%3==0?0:choose%3==1?1<<255:value;
        for(uint8 mode;mode<5;mode++) {
            compare(abi.encodeCall(sol.amount,(Currency.wrap(currency),Currency.wrap(address(0)),selected,mode)));
            compare(abi.encodeCall(sol.amount,(Currency.wrap(currency),Currency.wrap(address(token)),selected,mode)));
        }
    }
    function testFuzz_providerFailures(bytes memory response,bool reject,uint8 mode) public {
        manager.configure(true,reject,response);
        compare(abi.encodeCall(sol.read,(address(11),Currency.wrap(address(token)),mode%5)));
        compare(abi.encodeCall(sol.amount,(Currency.wrap(address(token)),Currency.wrap(address(0)),uint256(0),mode%5)));
    }
    function test_boundariesAndShortCircuit() public {
        setDelta(fe,address(token),type(int256).min);setDelta(address(sol),address(token),type(int256).min);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.amount,(Currency.wrap(address(token)),Currency.wrap(address(0)),uint256(0),uint8(0))));
        require(!ok && keccak256(out)==keccak256(abi.encodeWithSignature("Panic(uint256)",uint256(0x11))),"checked debt negation");
        manager.configure(true,true,hex"11223344");
        (ok,out)=compare(abi.encodeCall(sol.amount,(Currency.wrap(address(token)),Currency.wrap(address(0)),uint256(17),uint8(2))));
        require(ok && abi.decode(out,(uint256))==17,"explicit settle skips read");
        token.set(31);
        (ok,out)=compare(abi.encodeCall(sol.amount,(Currency.wrap(address(token)),Currency.wrap(address(token)),uint256(1)<<255,uint8(4))));
        require(ok && abi.decode(out,(uint256))==31,"balance sentinel skips debt");
        manager.configure(false,false,"");manager.set(CURRENCY,bytes32(uint256(1)<<160));manager.set(RESERVES,bytes32(uint256(99)));
        (ok,out)=compare(abi.encodeCall(sol.read,(address(0),Currency.wrap(address(0)),uint8(1))));
        require(ok && abi.decode(out,(uint256))==0,"masked native reserves");
    }
}
