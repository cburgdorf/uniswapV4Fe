// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import {Pool} from "./reference/src/libraries/Pool.sol";
import {TickMath} from "./reference/src/libraries/TickMath.sol";
import {TickBitmap} from "./reference/src/libraries/TickBitmap.sol";
import {Position} from "./reference/src/libraries/Position.sol";
import {BalanceDelta} from "./reference/src/types/BalanceDelta.sol";
import {Slot0} from "./reference/src/types/Slot0.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function load(address,bytes32) external view returns(bytes32);
    function store(address,bytes32,bytes32) external;
}
contract SolidityPoolHarness {
    using Pool for Pool.State;
    using Position for mapping(bytes32=>Position.State);
    using TickBitmap for mapping(int16=>uint256);
    function at(uint256 root) internal pure returns(Pool.State storage p) { assembly { p.slot:=root } }
    function initialize(uint256 root,uint160 price,uint24 fee) external returns(int24) { return at(root).initialize(price,fee); }
    function header(uint256 root) external view returns(uint256,uint256,uint256,uint128) {
        Pool.State storage p=at(root); return(uint256(Slot0.unwrap(p.slot0)),p.feeGrowthGlobal0X128,p.feeGrowthGlobal1X128,p.liquidity);
    }
    function setFees(uint256 root,uint24 protocol,uint24 lp) external { at(root).setProtocolFee(protocol); at(root).setLPFee(lp); }
    function checkInitialized(uint256 root) external view { at(root).checkPoolInitialized(); }
    function maxLiquidity(int24 spacing) external pure returns(uint128) { return Pool.tickSpacingToMaxLiquidityPerTick(spacing); }
    function readTick(uint256 root,int24 tick) external view returns(uint128,int128,uint256,uint256) {
        Pool.TickInfo storage t=at(root).ticks[tick]; return(t.liquidityGross,t.liquidityNet,t.feeGrowthOutside0X128,t.feeGrowthOutside1X128);
    }
    function updateTick(uint256 root,int24 tick,int128 delta,bool upper) external returns(bool,uint128) { return at(root).updateTick(tick,delta,upper); }
    function crossTick(uint256 root,int24 tick,uint256 growth0,uint256 growth1) external returns(int128) { return at(root).crossTick(tick,growth0,growth1); }
    function clearTick(uint256 root,int24 tick) external { at(root).clearTick(tick); }
    function inside(uint256 root,int24 lower,int24 upper) external view returns(uint256,uint256) { return at(root).getFeeGrowthInside(lower,upper); }
    function modify(uint256 root,address owner,int24 lower,int24 upper,int128 delta,int24 spacing,bytes32 salt) external returns(int256,int256) {
        (BalanceDelta a,BalanceDelta b)=at(root).modifyLiquidity(Pool.ModifyLiquidityParams(owner,lower,upper,delta,spacing,salt)); return(BalanceDelta.unwrap(a),BalanceDelta.unwrap(b));
    }
    function donate(uint256 root,uint256 a,uint256 b) external returns(int256) { return BalanceDelta.unwrap(at(root).donate(a,b)); }
    function swap(uint256 root,int256 amount,int24 spacing,bool zeroForOne,uint160 limit,uint24 overrideFee) external returns(int256,uint256,uint24,uint160,int24,uint128) {
        (BalanceDelta delta,uint256 protocol,uint24 fee,Pool.SwapResult memory r)=at(root).swap(Pool.SwapParams(amount,spacing,zeroForOne,limit,overrideFee));
        return(BalanceDelta.unwrap(delta),protocol,fee,r.sqrtPriceX96,r.tick,r.liquidity);
    }
    function readPosition(uint256 root,address owner,int24 lower,int24 upper,bytes32 salt) external view returns(uint128,uint256,uint256) {
        Position.State storage p=at(root).positions.get(owner,lower,upper,salt); return(p.liquidity,p.feeGrowthInside0LastX128,p.feeGrowthInside1LastX128);
    }
    function nextTick(uint256 root,int24 tick,int24 spacing,bool lte) external view returns(int24,bool) { return at(root).tickBitmap.nextInitializedTickWithinOneWord(tick,spacing,lte); }
}
contract PoolParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityPoolHarness sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt")); address deployed;
        assembly { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length!=0,"Fe deployment failed"); fe=deployed; sol=new SolidityPoolHarness();
    }
    function compare(bytes memory data) internal returns(bool,bytes memory) {
        (bool a,bytes memory x)=fe.call(data); (bool b,bytes memory y)=address(sol).call(data);
        require(a==b,"success/revert mismatch"); require(keccak256(x)==keccak256(y),"return/revert mismatch"); return(a,x);
    }
    function success(bytes memory data) internal returns(bytes memory) { (bool ok,bytes memory result)=compare(data); require(ok,"valid scenario reverted"); return result; }
    function sameSlot(bytes32 slot) internal view { require(vm.load(fe,slot)==vm.load(address(sol),slot),"storage mismatch"); }
    function seed(bytes32 slot,bytes32 value) internal { vm.store(fe,slot,value); vm.store(address(sol),slot,value); }
    function offset(uint256 root,uint256 index) internal pure returns(bytes32) { unchecked { return bytes32(root+index); } }
    function tickSlot(uint256 root,int24 tick) internal pure returns(uint256) { return uint256(keccak256(abi.encode(tick,offset(root,4)))); }
    function assertHeader(uint256 root) internal { for(uint256 i;i<7;++i) sameSlot(offset(root,i)); success(abi.encodeCall(sol.header,(root))); }
    function assertTick(uint256 root,int24 tick,int24 spacing) internal {
        uint256 slot=tickSlot(root,tick); for(uint256 i;i<3;++i) sameSlot(offset(slot,i));
        success(abi.encodeCall(sol.readTick,(root,tick)));
        if(spacing!=0) sameSlot(keccak256(abi.encode(int16((tick/spacing)>>8),offset(root,5))));
    }
    function assertPosition(uint256 root,address owner,int24 lower,int24 upper,bytes32 salt) internal {
        bytes32 key=keccak256(abi.encodePacked(owner,lower,upper,salt));
        uint256 slot=uint256(keccak256(abi.encode(key,offset(root,6))));
        for(uint256 i;i<3;++i) sameSlot(offset(slot,i)); success(abi.encodeCall(sol.readPosition,(root,owner,lower,upper,salt)));
    }
    function testFuzz_initialization(uint256 root,uint160 price,uint24 fee) public {
        compare(abi.encodeCall(sol.checkInitialized,(root)));
        compare(abi.encodeCall(sol.setFees,(root,fee,fee)));
        compare(abi.encodeCall(sol.initialize,(root,price,fee))); assertHeader(root);
        compare(abi.encodeCall(sol.initialize,(root,price,fee))); assertHeader(root);
        compare(abi.encodeCall(sol.setFees,(root,fee,fee))); assertHeader(root);
    }
    function testFuzz_maxLiquidity(int24 spacing) public { success(abi.encodeCall(sol.maxLiquidity,(spacing))); }
    struct TickCase { uint256 root; int24 current; int24 tick; uint256 packedLiquidity; uint256 outside0; uint256 outside1; uint256 global0; uint256 global1; int128 delta; bool upper; }
    function testFuzz_tickAccounting(TickCase memory t) public {
        seed(offset(t.root,0),bytes32((uint256(uint24(t.current))<<160)|uint256(1<<96)));
        seed(offset(t.root,1),bytes32(t.global0)); seed(offset(t.root,2),bytes32(t.global1));
        uint256 slot=tickSlot(t.root,t.tick);
        seed(offset(slot,0),bytes32(t.packedLiquidity)); seed(offset(slot,1),bytes32(t.outside0)); seed(offset(slot,2),bytes32(t.outside1));
        compare(abi.encodeCall(sol.updateTick,(t.root,t.tick,t.delta,t.upper))); assertTick(t.root,t.tick,1);
        success(abi.encodeCall(sol.crossTick,(t.root,t.tick,t.global0,t.global1))); assertTick(t.root,t.tick,1);
        success(abi.encodeCall(sol.clearTick,(t.root,t.tick))); assertTick(t.root,t.tick,1);
        require(vm.load(fe,bytes32(slot))==0,"tick not cleared");
    }
    function testFuzz_insideGrowth(uint256 root,int24 current,uint256 a,uint256 b,uint256 c,uint256 d,uint256 g0,uint256 g1) public {
        seed(offset(root,0),bytes32(uint256(uint24(current))<<160));
        seed(offset(root,1),bytes32(g0)); seed(offset(root,2),bytes32(g1));
        uint256 lo=tickSlot(root,-100); uint256 hi=tickSlot(root,100);
        seed(offset(lo,1),bytes32(a)); seed(offset(lo,2),bytes32(b)); seed(offset(hi,1),bytes32(c)); seed(offset(hi,2),bytes32(d));
        success(abi.encodeCall(sol.inside,(root,int24(-100),int24(100))));
    }
    struct Lifecycle { uint256 root; uint64 liquidity; uint64 amount; uint32 donation; uint24 fee; uint16 protocol; bool direction; bool exactInput; }
    function testFuzz_liquiditySwapLifecycle(Lifecycle memory c) public {
        uint128 liq=uint128(c.liquidity)+1000;
        uint24 fee=c.fee%1000000;
        uint24 protocol=uint24(c.protocol%1001); protocol|=protocol<<12;
        success(abi.encodeCall(sol.initialize,(c.root,uint160(1<<96),fee)));
        success(abi.encodeCall(sol.setFees,(c.root,protocol,fee)));
        success(abi.encodeCall(sol.modify,(c.root,address(this),int24(-600),int24(600),int128(liq),int24(10),bytes32(0))));
        assertTick(c.root,-600,10); assertTick(c.root,600,10); assertHeader(c.root);
        success(abi.encodeCall(sol.donate,(c.root,uint256(c.donation),uint256(c.donation)+1)));
        int256 amount=int256(uint256(c.amount))+1; if(c.exactInput) amount=-amount;
        uint160 limit=TickMath.getSqrtPriceAtTick(c.direction?int24(-700):int24(700));
        success(abi.encodeCall(sol.swap,(c.root,amount,int24(10),c.direction,limit,uint24(0))));
        assertHeader(c.root); assertTick(c.root,-600,10); assertTick(c.root,600,10);
        success(abi.encodeCall(sol.modify,(c.root,address(this),int24(-600),int24(600),int128(0),int24(10),bytes32(0))));
        assertPosition(c.root,address(this),-600,600,0);
        success(abi.encodeCall(sol.modify,(c.root,address(this),int24(-600),int24(600),-int128(liq),int24(10),bytes32(0))));
        assertHeader(c.root); assertTick(c.root,-600,10); assertTick(c.root,600,10); assertPosition(c.root,address(this),-600,600,0);
        compare(abi.encodeCall(sol.donate,(c.root,uint256(1),uint256(1))));
    }
    function test_multiTickCrossingsAndRoots() public {
        uint256[2] memory roots=[uint256(0),uint256(keccak256("second pool"))];
        for(uint256 r;r<2;++r) {
            success(abi.encodeCall(sol.initialize,(roots[r],uint160(1<<96),uint24(3000+1000*r))));
            success(abi.encodeCall(sol.setFees,(roots[r],uint24(1000|(500<<12)),uint24(3000+1000*r))));
            for(int24 i=-3;i<3;++i) {
                success(abi.encodeCall(sol.modify,(roots[r],address(this),i*100,(i+1)*100,int128(int256(1000000000*(r+1))),int24(1),bytes32(uint256(r)))));
            }
        }
        for(uint256 direction;direction<3;++direction) {
            bool zeroForOne=direction%2==0;
            for(uint256 r;r<2;++r) {
                int24 limitTick=zeroForOne?int24(-350):int24(350);
                success(abi.encodeCall(sol.swap,(roots[r],int256(-1000000000),int24(1),zeroForOne,TickMath.getSqrtPriceAtTick(limitTick),uint24(0))));
                assertHeader(roots[r]); assertHeader(roots[1-r]);
                for(int24 i=-3;i<=3;++i) assertTick(roots[r],i*100,1);
                for(int24 i=-3;i<3;++i) {
                    success(abi.encodeCall(sol.modify,(roots[r],address(this),i*100,(i+1)*100,int128(0),int24(1),bytes32(uint256(r)))));
                    assertPosition(roots[r],address(this),i*100,(i+1)*100,bytes32(uint256(r)));
                }
            }
        }
    }
    function test_tickOverflowAndGrowthWrap() public {
        uint256 root=888;
        success(abi.encodeCall(sol.initialize,(root,uint160(1<<96),uint24(3000))));
        uint256 slot=tickSlot(root,-1);
        seed(bytes32(slot),bytes32((uint256(uint128(type(int128).max))<<128)|1));
        compare(abi.encodeCall(sol.updateTick,(root,int24(-1),int128(1),false))); assertTick(root,-1,1);
        seed(bytes32(slot),bytes32((uint256(uint128(type(int128).min))<<128)|1));
        compare(abi.encodeCall(sol.updateTick,(root,int24(-1),int128(1),true))); assertTick(root,-1,1);
        seed(offset(root,3),bytes32(uint256(7)<<128|1));
        seed(offset(root,1),bytes32(type(uint256).max)); seed(offset(root,2),bytes32(type(uint256).max));
        success(abi.encodeCall(sol.donate,(root,uint256(1),uint256(1)))); assertHeader(root);
        require(uint256(vm.load(fe,offset(root,3)))>>128==7,"reserved liquidity bits");
        seed(offset(root,3),bytes32(uint256(7)<<128));
        success(abi.encodeCall(sol.modify,(root,address(this),int24(-10),int24(10),int128(1000),int24(1),bytes32(0))));
        assertHeader(root); require(uint256(vm.load(fe,offset(root,3)))>>128==7,"reserved bits on modify");
        success(abi.encodeCall(sol.swap,(root,int256(-10),int24(1),true,TickMath.getSqrtPriceAtTick(-11),uint24(0))));
        assertHeader(root); require(uint256(vm.load(fe,offset(root,3)))>>128==7,"reserved bits on swap");
    }
    function test_minimumSignedInputAndZeroLiquidity() public {
        uint256 root=777;
        success(abi.encodeCall(sol.initialize,(root,uint160(1<<96),uint24(0))));
        // An empty pool traverses bitmap words to the limit without consuming input.
        success(abi.encodeCall(sol.swap,(root,type(int256).min,int24(1),true,TickMath.getSqrtPriceAtTick(-600),uint24(0))));
        assertHeader(root);
        success(abi.encodeCall(sol.modify,(root,address(this),int24(-1000),int24(1000),int128(1000000),int24(1),bytes32(0))));
        compare(abi.encodeCall(sol.swap,(root,type(int256).min,int24(1),false,TickMath.getSqrtPriceAtTick(1001),uint24(0))));
        assertHeader(root); assertTick(root,-1000,1); assertTick(root,1000,1);
    }
    function test_errorsAndLimits() public {
        uint256 root=91;
        compare(abi.encodeCall(sol.donate,(root,uint256(1),uint256(1))));
        success(abi.encodeCall(sol.initialize,(root,uint160(1<<96),uint24(3000))));
        int24[6] memory lowers=[int24(1),-887273,-887272,-1,0,1];
        int24[6] memory uppers=[int24(0),0,887273,1,0,2];
        for(uint256 i;i<lowers.length;++i) {
            compare(abi.encodeCall(sol.modify,(root,address(this),lowers[i],uppers[i],int128(1000),int24(10),bytes32(0))));
            assertHeader(root); assertTick(root,lowers[i],10); assertTick(root,uppers[i],10);
        }
        compare(abi.encodeCall(sol.modify,(root,address(this),int24(-10),int24(10),type(int128).max,int24(10),bytes32(0))));
        assertHeader(root); assertTick(root,-10,10); assertTick(root,10,10);
        success(abi.encodeCall(sol.modify,(root,address(this),int24(-10),int24(10),int128(1000000),int24(10),bytes32(0))));
        uint160[6] memory limits=[uint160(0),TickMath.MIN_SQRT_PRICE,uint160(1<<96),TickMath.MAX_SQRT_PRICE,type(uint160).max,TickMath.getSqrtPriceAtTick(-10)];
        for(uint256 i;i<limits.length;++i) {
            compare(abi.encodeCall(sol.swap,(root,int256(-100),int24(10),true,limits[i],uint24(0))));
            assertHeader(root); assertTick(root,-10,10); assertTick(root,10,10);
        }
        success(abi.encodeCall(sol.setFees,(root,uint24(0),uint24(1000000))));
        compare(abi.encodeCall(sol.swap,(root,int256(1),int24(10),true,TickMath.MIN_SQRT_PRICE+1,uint24(0))));
        success(abi.encodeCall(sol.swap,(root,int256(0),int24(10),true,uint160(0),uint24(0))));
        success(abi.encodeCall(sol.swap,(root,int256(-100),int24(10),true,TickMath.MIN_SQRT_PRICE+1,uint24(0))));
        compare(abi.encodeCall(sol.swap,(root,int256(-100),int24(10),true,TickMath.MIN_SQRT_PRICE+1,uint24(0x400000|1000001))));
        success(abi.encodeCall(sol.swap,(root,int256(-100),int24(10),true,TickMath.MIN_SQRT_PRICE+1,uint24(0x400000|500))));
        compare(abi.encodeCall(sol.donate,(root,uint256(type(uint128).max),uint256(0))));
        assertHeader(root);
    }
}
