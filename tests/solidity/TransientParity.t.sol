// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import {Lock} from "./reference/src/libraries/Lock.sol";
import {NonzeroDeltaCount} from "./reference/src/libraries/NonzeroDeltaCount.sol";
import {CurrencyDelta} from "./reference/src/libraries/CurrencyDelta.sol";
import {CurrencyReserves} from "./reference/src/libraries/CurrencyReserves.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {BalanceDelta} from "./reference/src/types/BalanceDelta.sol";
interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
}
contract SolidityTransientHarness {
    function setUnlocked(bool value) external { if(value) Lock.unlock(); else Lock.lock(); }
    function unlocked() external view returns(bool) { return Lock.isUnlocked(); }
    function count() external view returns(uint256) { return NonzeroDeltaCount.read(); }
    function bump(bool increment) external { if(increment) NonzeroDeltaCount.increment(); else NonzeroDeltaCount.decrement(); }
    function deltaSlot(address currency,address target) external pure returns(uint256) { return uint256(CurrencyDelta._computeSlot(target,Currency.wrap(currency))); }
    function delta(address currency,address target) external view returns(int256) { return CurrencyDelta.getDelta(Currency.wrap(currency),target); }
    function applyDelta(address currency,address target,int128 change) external returns(int256,int256) { return CurrencyDelta.applyDelta(Currency.wrap(currency),target,change); }
    // This helper reproduces PoolManager._accountDelta; the four libraries above are unmodified.
    function account(address currency,address target,int128 change) public {
        if(change == 0) return;
        (int256 previous,int256 next)=CurrencyDelta.applyDelta(Currency.wrap(currency),target,change);
        if(next == 0) NonzeroDeltaCount.decrement();
        else if(previous == 0) NonzeroDeltaCount.increment();
    }
    function accountPool(address c0,address c1,address target,int256 packed) external {
        BalanceDelta d=BalanceDelta.wrap(packed);
        account(c0,target,d.amount0()); account(c1,target,d.amount1());
    }
    function sync(address currency,uint256 amount) external { CurrencyReserves.syncCurrencyAndReserves(Currency.wrap(currency),amount); }
    function reset() external { CurrencyReserves.resetCurrency(); }
    function synced() external view returns(address,uint256) { return (Currency.unwrap(CurrencyReserves.getSyncedCurrency()),CurrencyReserves.getSyncedReserves()); }
    function rawRead(uint256 slot) external view returns(uint256 value) { assembly { value := tload(slot) } }
    function rawWrite(uint256 slot,uint256 value) external { assembly { tstore(slot,value) } }
    function writeThenRevert(uint256 slot,uint256 value) external { assembly { tstore(slot,value) revert(0,0) } }
}
contract TransientParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    uint256 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    uint256 constant RESERVES=0x1e0745a7db1623981f0b2a5d4232364c00787266eb75ad546f190e6cebe9bd95;
    uint256 constant CURRENCY=0x27e098c505d44ec3574004bca052aabf76bd35004c182099d8c575fb238593b9;
    address fe;
    SolidityTransientHarness sol;
    function deployFe() internal returns(address deployed) {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        assembly { deployed := create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"deploy failed");
    }
    function setUp() public { fe=deployFe(); sol=new SolidityTransientHarness(); }
    function compare(bytes memory data) internal returns(bytes memory x) {
        bool a; (a,x)=fe.call(data);
        (bool b,bytes memory y)=address(sol).call(data);
        require(a==b,"success mismatch"); require(keccak256(x)==keccak256(y),"return/revert mismatch");
    }
    function read(uint256 slot) internal returns(uint256) { return abi.decode(compare(abi.encodeCall(sol.rawRead,(slot))),(uint256)); }
    function count() internal returns(uint256) { return abi.decode(compare(abi.encodeCall(sol.count,())),(uint256)); }
    function delta(address c,address t) internal returns(int256) { return abi.decode(compare(abi.encodeCall(sol.delta,(c,t))),(int256)); }
    function testFuzz_slotsAndCheckedAddition(address c,address t,int256 previous,int128 change) public {
        uint256 slot=uint256(keccak256(abi.encode(t,c)));
        require(abi.decode(compare(abi.encodeCall(sol.deltaSlot,(c,t))),(uint256))==slot,"key");
        compare(abi.encodeCall(sol.rawWrite,(slot,uint256(previous))));
        compare(abi.encodeCall(sol.applyDelta,(c,t,change)));
        int256 expected;
        unchecked { expected=previous+change; }
        bool overflow=(change>0 && expected<previous)||(change<0 && expected>previous);
        require(delta(c,t)==(overflow?previous:expected),"checked addition model");
    }
    function testFuzz_countWrap(uint256 initial,bool increment) public {
        compare(abi.encodeCall(sol.rawWrite,(COUNT,initial)));
        compare(abi.encodeCall(sol.bump,(increment)));
        uint256 expected; unchecked { expected=increment?initial+1:initial-1; }
        require(count()==expected,"count wrapping");
    }
    function testFuzz_lockAndReserves(address c,uint256 amount,bool unlocked) public {
        compare(abi.encodeCall(sol.setUnlocked,(unlocked)));
        require(abi.decode(compare(abi.encodeCall(sol.unlocked,())),(bool))==unlocked,"lock");
        require(read(LOCK)==(unlocked?1:0),"lock slot");
        compare(abi.encodeCall(sol.sync,(c,amount)));
        require(read(CURRENCY)==uint160(c) && read(RESERVES)==amount,"reserve slots");
        compare(abi.encodeCall(sol.synced,()));
        compare(abi.encodeCall(sol.reset,()));
        (address currency,uint256 reserves)=abi.decode(compare(abi.encodeCall(sol.synced,())),(address,uint256));
        require(currency==address(0) && reserves==amount,"reset must retain reserves");
    }
    function testFuzz_accountSequence(address c,address t,int128 a,int128 b) public {
        compare(abi.encodeCall(sol.account,(c,t,a)));
        require(count()==(a==0?0:1),"initial count");
        compare(abi.encodeCall(sol.account,(c,t,b)));
        int256 sum=int256(a)+b;
        require(delta(c,t)==sum && count()==(sum==0?0:1),"sequence model");
        compare(abi.encodeCall(sol.account,(c,t,0)));
        require(count()==(sum==0?0:1),"zero fast path");
        // Inverse MIN_INT128 needs two legal int128 pieces.
        undo(c,t,b); undo(c,t,a);
        require(delta(c,t)==0 && count()==0,"balanced account");
    }
    function undo(address c,address t,int128 value) internal {
        if(value==type(int128).min) {
            compare(abi.encodeCall(sol.account,(c,t,type(int128).max)));
            compare(abi.encodeCall(sol.account,(c,t,int128(1))));
        } else compare(abi.encodeCall(sol.account,(c,t,-value)));
    }
    function testFuzz_poolDelta(address c0,address c1,address t,int128 a,int128 b) public {
        int256 packed=(int256(a)<<128)|int256(uint256(uint128(b)));
        compare(abi.encodeCall(sol.accountPool,(c0,c1,t,packed)));
        uint256 expected;
        if(c0==c1) { expected=int256(a)+b==0?0:1; require(delta(c0,t)==int256(a)+b,"same currency"); }
        else { expected=(a==0?0:1)+(b==0?0:1); require(delta(c0,t)==a && delta(c1,t)==b,"separate currencies"); }
        require(count()==expected,"pool count");
    }
    function testFuzz_revertAndStaticcall(uint256 slot,uint256 initial,uint256 replacement) public {
        compare(abi.encodeCall(sol.rawWrite,(slot,initial)));
        (bool a,bytes memory x)=fe.call(abi.encodeCall(sol.writeThenRevert,(slot,replacement)));
        (bool b,bytes memory y)=address(sol).call(abi.encodeCall(sol.writeThenRevert,(slot,replacement)));
        require(!a && !b && x.length==0 && y.length==0,"empty revert");
        require(read(slot)==initial,"rollback");
        // Bound gas: exceptional TSTORE in static context consumes forwarded gas.
        (a,)=fe.staticcall{gas:100000}(abi.encodeCall(sol.rawWrite,(slot,replacement)));
        (b,)=address(sol).staticcall{gas:100000}(abi.encodeCall(sol.rawWrite,(slot,replacement)));
        require(!a && !b && read(slot)==initial,"static store");
    }
    function test_boundariesAndIsolation() public {
        testFuzz_countWrap(0,false); testFuzz_countWrap(type(uint256).max,true);
        compare(abi.encodeCall(sol.rawWrite,(COUNT,0)));
        testFuzz_slotsAndCheckedAddition(address(1),address(2),type(int256).max,1);
        testFuzz_slotsAndCheckedAddition(address(1),address(2),type(int256).min,-1);
        testFuzz_accountSequence(address(3),address(4),type(int128).min,type(int128).min);
        testFuzz_poolDelta(address(5),address(5),address(6),17,-17);
        compare(abi.encodeCall(sol.account,(address(7),address(8),int128(1))));
        compare(abi.encodeCall(sol.account,(address(7),address(9),int128(-1))));
        require(count()==2 && delta(address(7),address(8))==1 && delta(address(7),address(9))==-1,"account isolation");
        address other=deployFe();
        (bool ok,bytes memory out)=other.call(abi.encodeCall(sol.count,()));
        require(ok && abi.decode(out,(uint256))==0,"contract isolation");
        compare(abi.encodeCall(sol.setUnlocked,(true)));
        (ok,out)=other.call(abi.encodeCall(sol.unlocked,()));
        require(ok && !abi.decode(out,(bool)),"lock isolation");
    }
    function test_atomicPoolDeltaOverflow() public {
        uint256 slot=uint256(keccak256(abi.encode(address(3),address(2))));
        compare(abi.encodeCall(sol.rawWrite,(slot,uint256(type(int256).max))));
        bytes memory callData=abi.encodeCall(sol.accountPool,(address(1),address(2),address(3),(int256(1)<<128)|1));
        bytes memory result=compare(callData);
        require(keccak256(result)==keccak256(abi.encodeWithSignature("Panic(uint256)",0x11)),"overflow panic");
        require(delta(address(1),address(3))==0 && count()==0,"rollback first delta and count");
        require(delta(address(2),address(3))==type(int256).max,"rollback second delta");
    }
}
