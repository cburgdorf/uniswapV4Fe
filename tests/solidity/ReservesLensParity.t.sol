// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReservesLens} from "./periphery/src/lens/ReservesLens.sol";
import {IReservesLens} from "./periphery/src/interfaces/IReservesLens.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {TickMath} from "./reference/src/libraries/TickMath.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract LensManager {
    mapping(bytes32=>bytes32) words;
    uint8 public mode;
    function set(bytes32 slot,bytes32 value) external {words[slot]=value;}
    function configure(uint8 m) external {mode=m;}
    function extsload(bytes32 slot) external view returns(bytes32) {return words[slot];}
    function extsload(bytes32[] calldata slots) external view returns(bytes32[] memory out) {
        if(mode==1)revert("manager rejects batch");
        out=new bytes32[](mode==2?0:slots.length);
        for(uint256 i;i<out.length;i++)out[i]=words[slots[i]];
    }
}
contract StatsProvider {
    uint8 public mode;
    function configure(uint8 m) external {mode=m;}
    function supportsInterface(bytes4 id) external view returns(bool) {
        if(mode==1)return false;
        if(mode==7)assembly {mstore(0,1) return(0,31)}
        if(id==0xffffffff)return false;
        if(mode==6)assembly {mstore(0,2) return(0,32)}
        return true;
    }
    function hook() external view returns(address) {return mode==2?address(0):address(this);}
    function getReserves(PoolKey calldata) external view returns(uint256,uint256) {
        if(mode==3)revert("stats reject");
        if(mode==4)assembly {mstore(0,100) return(0,32)}
        if(mode==8)assembly {return(0,10000)}
        return (100,200);
    }
    function getEffectiveLiquidity(PoolKey calldata) external view returns(uint256,uint256) {return mode==5?(101,200):(90,180);}
}
contract ReservesLensParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;ReservesLens sol;LensManager manager;StatsProvider stats;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");
        fe=f;sol=new ReservesLens();manager=new LensManager();stats=new StatsProvider();
    }
    function key(bool hook) internal view returns(PoolKey memory) {return PoolKey(Currency.wrap(address(10)),Currency.wrap(address(20)),3000,60,IHooks(hook?address(stats):address(0)));}
    function root(PoolKey memory k) internal pure returns(bytes32) {return keccak256(abi.encode(keccak256(abi.encode(k)),uint256(6)));}
    function seed(PoolKey memory k,uint128 liquidity,int24 tick) internal {
        bytes32 base=root(k);
        manager.set(base,bytes32(uint256(TickMath.getSqrtPriceAtTick(tick))|(uint256(uint24(tick))<<160)));
        manager.set(bytes32(uint256(base)+3),bytes32(uint256(tick>=-600&&tick<600?liquidity:0)));
        int24 lower=int24(-600)/k.tickSpacing;int24 upper=int24(600)/k.tickSpacing;
        manager.set(keccak256(abi.encode(int256(lower>>8),uint256(base)+5)),bytes32(uint256(1)<<uint8(uint24(lower))));
        manager.set(keccak256(abi.encode(int256(upper>>8),uint256(base)+5)),bytes32(uint256(1)<<uint8(uint24(upper))));
        manager.set(keccak256(abi.encode(int256(-600),uint256(base)+4)),bytes32(uint256(liquidity)|(uint256(liquidity)<<128)));
        manager.set(keccak256(abi.encode(int256(600),uint256(base)+4)),bytes32(uint256(liquidity)|(uint256(uint128(-int128(liquidity)))<<128)));
    }
    function compare(bytes memory data) internal returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall(data);(bool expected,bytes memory ref)=address(sol).staticcall(data);
        require(ok==expected,"lens status mismatch");require(keccak256(out)==keccak256(ref),"lens bytes mismatch");
    }
    function full(PoolKey memory k) internal returns(bytes memory) {
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k));require(ok,"full scan");return out;
    }
    function testFuzz_tvl(uint64 amount,int16 current,bool hook,uint8 mode) public {
        PoolKey memory k=key(hook);stats.configure(mode%9);seed(k,uint128(amount)+1,int24(current)%1201);full(k);
        (bool ok,)=compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address),address)",manager,k,stats));require(ok,"explicit provider");
    }
    function testFuzz_paged(uint64 amount,int16 current,uint16 reads) public {
        PoolKey memory k=key(false);seed(k,uint128(amount)+1,int24(current)%1201);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),bytes(""),uint32(reads%64+2)));require(ok,"first page");
        (IReservesLens.PoolTVL memory value,bytes memory cursor,bool done)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        if(!done) {
            (ok,out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),cursor,uint32(4096)));require(ok,"second page");
            (value,cursor,done)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        }
        require(done&&cursor.length==0,"complete cursor");require(keccak256(abi.encode(value))==keccak256(full(k)),"paged equals complete");
    }
    function test_ticksBatchAndInvalidState() public {
        PoolKey memory k=key(false);seed(k,10000,0);
        compare(abi.encodeWithSignature("getPopulatedTicksInWord(address,(address,address,uint24,int24,address),int16)",manager,k,int16(-1)));
        compare(abi.encodeWithSignature("getPopulatedTicksInWord(address,(address,address,uint24,int24,address),int16)",manager,k,int16(0)));
        PoolKey[] memory keys=new PoolKey[](2);keys[0]=k;keys[1]=k;
        compare(abi.encodeWithSignature("getPoolTVLBatch(address,(address,address,uint24,int24,address)[])",manager,keys));
        compare(abi.encodeWithSignature("getPoolTVLBatch(address,(address,address,uint24,int24,address)[],address[])",manager,keys,new address[](2)));
        compare(abi.encodeWithSignature("getPoolTVLBatch(address,(address,address,uint24,int24,address)[],address[])",manager,keys,new address[](0)));
        manager.configure(1);compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k));
        manager.configure(2);compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k));
        manager.configure(0);manager.set(bytes32(uint256(root(k))+3),bytes32(uint256(9999)));
        compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k));
        k.tickSpacing=0;compare(abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k));
    }
    function test_cursorValidation() public {
        PoolKey memory k=key(false);seed(k,10000,0);
        (,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),bytes(""),uint32(2)));
        (,bytes memory cursor,)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        uint256[6] memory indexes=[uint256(0),1,2,3,5,7];
        for(uint256 i;i<indexes.length;i++) {
            bytes memory dirty=bytes.concat(cursor);uint256 at=32+indexes[i]*32;
            assembly {mstore(add(dirty,at),257)}
            compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),dirty,uint32(2)));
        }
        compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),bytes)",manager,k,hex"01"));
    }
    function test_lowGasHookStatus() public {
        PoolKey memory k=key(true);seed(k,10000,0);
        bytes memory data=abi.encodeWithSignature("getPoolTVL(address,(address,address,uint24,int24,address))",manager,k);
        (bool ok,bytes memory out)=fe.staticcall{gas:1600000}(data);
        (bool refOk,bytes memory expected)=address(sol).staticcall{gas:1600000}(data);
        require(ok&&refOk,"low gas core scan completes");require(keccak256(out)==keccak256(expected),"low gas result parity");
        IReservesLens.PoolTVL memory value=abi.decode(out,(IReservesLens.PoolTVL));
        require(value.statsStatus==IReservesLens.HookStatsStatus.INSUFFICIENT_GAS,"stats deferred");
    }

    function testFuzz_overlappingRanges(uint64 a,uint64 b,int16 current,bool zeroNet) public {
        PoolKey memory k=key(false);uint128 first=uint128(a)+1;uint128 second=uint128(b)+1;int24 tick=int24(current)%1001;
        seed(k,first,tick);bytes32 base=root(k);
        uint128 active=(tick>=-600&&tick<600?first:0)+(tick>=-120&&tick<120?second:0);
        manager.set(bytes32(uint256(base)+3),bytes32(uint256(active)));
        manager.set(keccak256(abi.encode(int256(-1),uint256(base)+5)),bytes32((uint256(1)<<246)|(uint256(1)<<254)));
        manager.set(keccak256(abi.encode(int256(0),uint256(base)+5)),bytes32((uint256(1)<<10)|(uint256(1)<<2)|(zeroNet?1:0)));
        manager.set(keccak256(abi.encode(int256(-120),uint256(base)+4)),bytes32(uint256(second)|(uint256(second)<<128)));
        manager.set(keccak256(abi.encode(int256(120),uint256(base)+4)),bytes32(uint256(second)|(uint256(uint128(-int128(second)))<<128)));
        if(zeroNet)manager.set(keccak256(abi.encode(int256(0),uint256(base)+4)),bytes32(uint256(2)));
        full(k);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),bytes)",manager,k,bytes("")));
        require(ok,"overlap paged scan");(IReservesLens.PoolTVL memory value,,bool done)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        require(done&&keccak256(abi.encode(value))==keccak256(full(k)),"overlap amount parity");
    }

    function test_resumeInsideWord() public {
        testFuzz_overlappingRanges(100,200,0,true);
        PoolKey memory k=key(false);
        (,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),bytes(""),uint32(2)));
        (,bytes memory cursor,)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        // Skipped words are empty; cursor positions are explicitly caller-trusted.
        assembly {mstore(add(cursor,224),not(0))}
        for(uint256 i;i<4;i++) {
            (bool ok,bytes memory step)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),cursor,uint32(2)));
            require(ok,"mid-word page");(,cursor,)=abi.decode(step,(IReservesLens.PoolTVL,bytes,bool));
            require(cursor.length==480,"continuation cursor");
        }
        (bool ok,bytes memory finalPage)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),cursor,uint32(4096)));
        require(ok,"remaining scan");(IReservesLens.PoolTVL memory value,,bool done)=abi.decode(finalPage,(IReservesLens.PoolTVL,bytes,bool));
        require(done&&keccak256(abi.encode(value))==keccak256(full(k)),"mid-word pages equal complete");
    }

    function test_largeBitmapDomain() public {
        PoolKey memory k=key(false);k.tickSpacing=1;seed(k,10000,0);
        bytes memory complete=full(k);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),bytes(""),uint32(4096)));
        require(ok,"large first page");(,bytes memory cursor,bool done)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));require(!done,"requires continuation");
        (ok,out)=compare(abi.encodeWithSignature("getPoolTVLPaged(address,(address,address,uint24,int24,address),address,bytes,uint32)",manager,k,address(0),cursor,uint32(4096)));
        require(ok,"large second page");(IReservesLens.PoolTVL memory value,,bool finished)=abi.decode(out,(IReservesLens.PoolTVL,bytes,bool));
        require(finished&&keccak256(abi.encode(value))==keccak256(complete),"batched and paged full domain");
    }

}
