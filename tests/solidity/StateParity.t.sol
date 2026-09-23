// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;
import {TickBitmap} from "./reference/src/libraries/TickBitmap.sol";
import {Position} from "./reference/src/libraries/Position.sol";
interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
    function load(address,bytes32) external view returns (bytes32);
    function store(address,bytes32,bytes32) external;
}
contract SolidityStateHarness {
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.State);
    using Position for Position.State;
    mapping(int16 => uint256) bitmap;
    mapping(bytes32 => Position.State) positions;
    function compress(int24 tick, int24 spacing) external pure returns (int24) { return TickBitmap.compress(tick,spacing); }
    function bitmapPosition(int24 tick) external pure returns (int16,uint8) { return TickBitmap.position(tick); }
    function flip(int24 tick, int24 spacing) external { bitmap.flipTick(tick,spacing); }
    function nextTick(int24 tick, int24 spacing, bool lte) external view returns (int24,bool) { return bitmap.nextInitializedTickWithinOneWord(tick,spacing,lte); }
    function word(int16 key) external view returns(uint256) { return bitmap[key]; }
    function setWord(int16 key,uint256 value) external { bitmap[key]=value; }
    function positionKey(address owner,int24 lower,int24 upper,bytes32 salt) external pure returns(uint256) { return uint256(Position.calculatePositionKey(owner,lower,upper,salt)); }
    function updatePosition(address owner,int24 lower,int24 upper,bytes32 salt,int128 delta,uint256 growth0,uint256 growth1) external returns(uint256,uint256) { return positions.get(owner,lower,upper,salt).update(delta,growth0,growth1); }
    function readPosition(address owner,int24 lower,int24 upper,bytes32 salt) external view returns(uint128,uint256,uint256) {
        Position.State storage p=positions.get(owner,lower,upper,salt);
        return (p.liquidity,p.feeGrowthInside0LastX128,p.feeGrowthInside1LastX128);
    }
}
contract StateParityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityStateHarness sol;
    function setUp() public {
        bytes memory initcode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed;
        assembly { deployed:=create(0,add(initcode,32),mload(initcode)) }
        require(deployed.code.length!=0,"Fe deploy failed");
        fe=deployed;
        sol=new SolidityStateHarness();
    }
    function compare(bytes memory data) internal returns(bytes memory) {
        (bool a,bytes memory x)=fe.call(data);
        (bool b,bytes memory y)=address(sol).call(data);
        require(a==b,"success/revert mismatch");
        require(keccak256(x)==keccak256(y),"return/revert mismatch");
        return x;
    }
    function sameSlot(bytes32 slot) internal view { require(vm.load(fe,slot)==vm.load(address(sol),slot),"storage mismatch"); }
    function testFuzz_compressAndPosition(int24 tick,int24 spacing) public {
        compare(abi.encodeCall(sol.compress,(tick,spacing)));
        compare(abi.encodeCall(sol.bitmapPosition,(tick)));
    }
    function testFuzz_bitmapSearch(int24 tick,int24 spacing,uint256 wordBits) public {
        int24 compressed=sol.compress(tick,spacing);
        (int16 key,)=sol.bitmapPosition(compressed);
        compare(abi.encodeCall(sol.setWord,(key,wordBits)));
        sameSlot(keccak256(abi.encode(key,uint256(0))));
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,true)));
        unchecked { (key,)=sol.bitmapPosition(compressed+1); }
        compare(abi.encodeCall(sol.setWord,(key,wordBits)));
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,false)));
    }
    function testFuzz_flip(int24 tick,int24 spacing) public {
        compare(abi.encodeCall(sol.flip,(tick,spacing)));
        int256 quotient;
        assembly { quotient:=sdiv(signextend(2,tick),signextend(2,spacing)) }
        bytes32 slot=keccak256(abi.encode(quotient>>8,uint256(0)));
        sameSlot(slot);
        compare(abi.encodeCall(sol.flip,(tick,spacing)));
        sameSlot(slot);
        require(vm.load(fe,slot)==bytes32(0),"double flip did not restore");
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,true)));
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,false)));
    }
    function testFuzz_alignedFlipAndSearch(int16 compressed,uint16 spacingSeed,uint256 initial) public {
        int24 spacing=int24(uint24(spacingSeed%127+1));
        int24 tick=int24(compressed)*spacing;
        (int16 key,)=sol.bitmapPosition(compressed);
        compare(abi.encodeCall(sol.setWord,(key,initial)));
        compare(abi.encodeCall(sol.flip,(tick,spacing)));
        sameSlot(keccak256(abi.encode(key,uint256(0))));
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,true)));
        compare(abi.encodeCall(sol.nextTick,(tick,spacing,false)));
        compare(abi.encodeCall(sol.flip,(tick,spacing)));
        require(abi.decode(compare(abi.encodeCall(sol.word,(key))),(uint256))==initial,"double flip changed word");
    }
    struct PositionCase {
        address owner;
        int24 lower;
        int24 upper;
        bytes32 salt;
        uint256 liquiditySlot;
        uint256 previous0;
        uint256 previous1;
        int128 delta;
        uint256 next0;
        uint256 next1;
    }
    function testFuzz_position(PositionCase memory p) public {
        bytes32 key=keccak256(abi.encodePacked(p.owner,p.lower,p.upper,p.salt));
        require(abi.decode(compare(abi.encodeCall(sol.positionKey,(p.owner,p.lower,p.upper,p.salt))),(uint256))==uint256(key),"position hash");
        uint256 slot=uint256(keccak256(abi.encode(key,uint256(1))));
        vm.store(fe,bytes32(slot),bytes32(p.liquiditySlot));
        vm.store(address(sol),bytes32(slot),bytes32(p.liquiditySlot));
        vm.store(fe,bytes32(slot+1),bytes32(p.previous0));
        vm.store(address(sol),bytes32(slot+1),bytes32(p.previous0));
        vm.store(fe,bytes32(slot+2),bytes32(p.previous1));
        vm.store(address(sol),bytes32(slot+2),bytes32(p.previous1));
        compare(abi.encodeCall(sol.updatePosition,(p.owner,p.lower,p.upper,p.salt,p.delta,p.next0,p.next1)));
        sameSlot(bytes32(slot)); sameSlot(bytes32(slot+1)); sameSlot(bytes32(slot+2));
        require(uint256(vm.load(fe,bytes32(slot)))>>128==p.liquiditySlot>>128,"reserved position bits changed");
        compare(abi.encodeCall(sol.readPosition,(p.owner,p.lower,p.upper,p.salt)));
        // A subsequent poke must use the updated checkpoint if the update succeeded.
        compare(abi.encodeCall(sol.updatePosition,(p.owner,p.lower,p.upper,p.salt,int128(0),p.next0,p.next1)));
        sameSlot(bytes32(slot)); sameSlot(bytes32(slot+1)); sameSlot(bytes32(slot+2));
    }
    function test_positionLifecycle() public {
        address owner=address(0x1234);
        int24 lower=-123;
        int24 upper=456;
        bytes32 salt=bytes32(uint256(7));
        compare(abi.encodeCall(sol.updatePosition,(owner,lower,upper,salt,int128(0),uint256(0),uint256(0))));
        bytes memory added=compare(abi.encodeCall(sol.updatePosition,(owner,lower,upper,salt,int128(100),uint256(0),uint256(0))));
        require(keccak256(added)==keccak256(abi.encode(uint256(0),uint256(0))),"initial fees");
        bytes memory fees=compare(abi.encodeCall(sol.updatePosition,(owner,lower,upper,salt,int128(-40),uint256(2)<<128,uint256(3)<<128)));
        require(keccak256(fees)==keccak256(abi.encode(uint256(200),uint256(300))),"old liquidity fee calculation");
        compare(abi.encodeCall(sol.updatePosition,(owner,lower,upper,salt,int128(-60),uint256(3)<<128,uint256(4)<<128)));
        compare(abi.encodeCall(sol.updatePosition,(owner,lower,upper,salt,int128(0),uint256(0),uint256(0))));
        compare(abi.encodeCall(sol.readPosition,(owner,lower,upper,salt)));
    }
    function test_bitmapBoundaries() public {
        int24[13] memory ticks=[type(int24).min,int24(-887272),-257,-256,-255,-1,0,1,255,256,257,887272,type(int24).max];
        int24[7] memory spacings=[type(int24).min,int24(-1),0,1,10,32767,type(int24).max];
        for(uint256 t;t<ticks.length;++t) for(uint256 s;s<spacings.length;++s) {
            compare(abi.encodeCall(sol.compress,(ticks[t],spacings[s])));
            compare(abi.encodeCall(sol.flip,(ticks[t],spacings[s])));
            int256 quotient;
            int24 tick=ticks[t];int24 spacing=spacings[s];
            assembly { quotient:=sdiv(signextend(2,tick),signextend(2,spacing)) }
            sameSlot(keccak256(abi.encode(quotient>>8,uint256(0))));
            compare(abi.encodeCall(sol.nextTick,(ticks[t],spacings[s],true)));
            compare(abi.encodeCall(sol.nextTick,(ticks[t],spacings[s],false)));
        }
        for(uint256 bit;bit<256;++bit) {
            compare(abi.encodeCall(sol.setWord,(int16(-1),uint256(1)<<bit)));
            compare(abi.encodeCall(sol.nextTick,(int24(-1),int24(1),true)));
            compare(abi.encodeCall(sol.nextTick,(int24(-257),int24(1),false)));
        }
    }
}
