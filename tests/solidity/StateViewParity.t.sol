// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {StateView} from "./periphery/src/lens/StateView.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function store(address,bytes32,bytes32) external;
    function etch(address,bytes calldata) external;
    function expectCall(address,bytes calldata,uint64) external;
    function mockCall(address,bytes calldata,bytes calldata) external;
    function clearMockedCalls() external;
}
contract RejectingReader { fallback() external { assembly {mstore(0,0x112233445566) revert(26,6)} } }
contract RawReader {
    bytes data;
    function configure(bytes memory value) external {data=value;}
    fallback() external {bytes memory value=data;assembly {return(add(value,32),mload(value))}}
}
contract StateViewParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    PoolManager manager;
    address fe;
    StateView sol;
    function setUp() public {
        manager=new PoolManager(address(this));
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(manager)));
        address deployed;assembly {deployed:=create(0,add(code,32),mload(code))}
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new StateView(manager);
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall(data);(bool other,bytes memory expected)=address(sol).staticcall(data);
        require(ok==other,"status mismatch");require(keccak256(out)==keccak256(expected),"return/revert mismatch");
    }
    function root(bytes32 id) internal pure returns(uint256) {return uint256(keccak256(abi.encode(id,uint256(6))));}
    function tickSlot(bytes32 id,int24 tick) internal pure returns(uint256) {return uint256(keccak256(abi.encode(int256(tick),root(id)+4)));}
    function positionSlot(bytes32 id,bytes32 key) internal pure returns(uint256) {return uint256(keccak256(abi.encode(key,root(id)+6)));}
    function write(uint256 slot,uint256 value) internal {vm.store(address(manager),bytes32(slot),bytes32(value));}
    function testFuzz_header(bytes32 id,uint256 word,uint256 growth0,uint256 growth1,uint256 liquidity) public {
        uint256 slot=root(id);write(slot,word);write(slot+1,growth0);write(slot+2,growth1);write(slot+3,liquidity);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.getSlot0,(PoolId.wrap(id))));require(ok,"slot0");
        (uint160 price,int24 tick,uint24 protocol,uint24 fee)=abi.decode(out,(uint160,int24,uint24,uint24));
        require(price==uint160(word) && tick==int24(uint24(word>>160)) && protocol==uint24(word>>184) && fee==uint24(word>>208),"slot0 model");
        vm.expectCall(address(manager),abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(slot+1),uint256(2)),2);
        (ok,)=compare(abi.encodeCall(sol.getFeeGrowthGlobals,(PoolId.wrap(id))));require(ok,"globals");
        (ok,out)=compare(abi.encodeCall(sol.getLiquidity,(PoolId.wrap(id))));require(ok && abi.decode(out,(uint128))==uint128(liquidity),"liquidity truncation");
    }
    function testFuzz_tick(bytes32 id,int24 tick,uint256 word,uint256 a,uint256 b) public {
        uint256 slot=tickSlot(id,tick);write(slot,word);write(slot+1,a);write(slot+2,b);
        vm.expectCall(address(manager),abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(slot),uint256(3)),2);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.getTickInfo,(PoolId.wrap(id),tick)));require(ok,"tick info");
        (uint128 gross,int128 net,uint256 x,uint256 y)=abi.decode(out,(uint128,int128,uint256,uint256));
        require(gross==uint128(word) && net==int128(uint128(word>>128)) && x==a && y==b,"tick model");
        (ok,)=compare(abi.encodeCall(sol.getTickLiquidity,(PoolId.wrap(id),tick)));require(ok,"tick liquidity");
        (ok,)=compare(abi.encodeCall(sol.getTickFeeGrowthOutside,(PoolId.wrap(id),tick)));require(ok,"outside growth");
    }
    function testFuzz_bitmap(bytes32 id,int16 word,uint256 bits) public {
        write(uint256(keccak256(abi.encode(int256(word),root(id)+5))),bits);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.getTickBitmap,(PoolId.wrap(id),word)));
        require(ok && abi.decode(out,(uint256))==bits,"bitmap");
    }
    function testFuzz_position(bytes32 id,address owner,int24 lower,int24 upper,bytes32 salt,uint256 liquidity,uint256 a,uint256 b) public {
        bytes32 key=keccak256(abi.encodePacked(owner,lower,upper,salt));uint256 slot=positionSlot(id,key);
        write(slot,liquidity);write(slot+1,a);write(slot+2,b);
        (bool ok,bytes memory out)=compare(abi.encodeWithSignature("getPositionInfo(bytes32,address,int24,int24,bytes32)",id,owner,lower,upper,salt));require(ok,"position by owner");
        (uint128 amount,uint256 x,uint256 y)=abi.decode(out,(uint128,uint256,uint256));require(amount==uint128(liquidity) && x==a && y==b,"position model");
        (ok,)=compare(abi.encodeWithSignature("getPositionInfo(bytes32,bytes32)",id,key));require(ok,"position by id");
        (ok,out)=compare(abi.encodeCall(sol.getPositionLiquidity,(PoolId.wrap(id),key)));require(ok && abi.decode(out,(uint128))==uint128(liquidity),"position liquidity");
    }
    function testFuzz_inside(bytes32 id,int24 current,int24 lower,int24 upper,uint256[6] memory growth) public {
        write(root(id),uint256(uint24(current))<<160);write(root(id)+1,growth[0]);write(root(id)+2,growth[1]);
        write(tickSlot(id,lower)+1,growth[2]);write(tickSlot(id,lower)+2,growth[3]);write(tickSlot(id,upper)+1,growth[4]);write(tickSlot(id,upper)+2,growth[5]);
        (bool ok,)=compare(abi.encodeCall(sol.getFeeGrowthInside,(PoolId.wrap(id),lower,upper)));require(ok,"wrapping fee growth");
    }
    function test_initializedPoolAndFailureBubbling() public {
        PoolKey memory key=PoolKey(Currency.wrap(address(0)),Currency.wrap(address(1234)),3000,60,IHooks(address(0)));
        manager.initialize(key,uint160(1<<96));
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.getSlot0,(key.toId())));require(ok,"initialized pool");
        (uint160 price,int24 tick,,uint24 fee)=abi.decode(out,(uint160,int24,uint24,uint24));require(price==1<<96 && tick==0 && fee==3000,"initialized model");
        (ok,out)=compare(abi.encodeCall(sol.poolManager,()));require(ok && abi.decode(out,(address))==address(manager),"immutable getter");
        RejectingReader reject=new RejectingReader();vm.etch(address(manager),address(reject).code);
        (ok,out)=compare(abi.encodeCall(sol.getSlot0,(key.toId())));require(!ok && keccak256(out)==keccak256(hex"112233445566"),"bubble failure");
        (ok,out)=compare(abi.encodeCall(sol.getTickInfo,(key.toId(),int24(-1))));require(!ok && keccak256(out)==keccak256(hex"112233445566"),"bubble range failure");
    }
    function testFuzz_rawRangeReturn(uint8 size,uint256 offset,uint256 length) public {
        RawReader raw=new RawReader();
        bytes memory response=new bytes(size);
        if(size>=32)assembly {mstore(add(response,32),offset)}
        if(size>=64)assembly {mstore(add(response,64),length)}
        raw.configure(response);
        bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(raw)));
        address deployed;assembly {deployed:=create(0,add(code,32),mload(code))}require(deployed.code.length>0,"raw-view deploy");
        fe=deployed;sol=new StateView(IPoolManager(address(raw)));
        compare(abi.encodeCall(sol.getTickInfo,(PoolId.wrap(bytes32(0)),int24(0))));
        compare(abi.encodeCall(sol.getTickFeeGrowthOutside,(PoolId.wrap(bytes32(0)),int24(0))));
        compare(abi.encodeCall(sol.getFeeGrowthGlobals,(PoolId.wrap(bytes32(0)))));
        compare(abi.encodeWithSignature("getPositionInfo(bytes32,bytes32)",bytes32(0),bytes32(0)));
        compare(abi.encodeWithSignature("getPositionInfo(bytes32,address,int24,int24,bytes32)",bytes32(0),address(0),int24(0),int24(1),bytes32(0)));
        compare(abi.encodeCall(sol.getFeeGrowthInside,(PoolId.wrap(bytes32(0)),int24(0),int24(1))));
    }
    function test_shortRangeArrays() public {
        testFuzz_rawRangeReturn(32,0,0);
        testFuzz_rawRangeReturn(64,32,0);
        testFuzz_rawRangeReturn(96,32,1);
        testFuzz_rawRangeReturn(128,32,2);
        testFuzz_rawRangeReturn(160,32,3);
        testFuzz_rawRangeReturn(64,32,type(uint256).max);
        for(uint256 i=0;i<40;i++) testFuzz_rawRangeReturn(64,32,(type(uint64).max/32)-i);
    }

    function test_laterAllocationBoundaries() public {
        bytes32 id=bytes32(0);
        for(uint256 side=0;side<2;side++) {
            for(uint256 i=0;i<45;i++) {
                vm.clearMockedCalls();
                bytes memory request=abi.encodeWithSignature("extsload(bytes32,uint256)",bytes32(tickSlot(id,int24(int256(side)))+1),uint256(2));
                vm.mockCall(address(manager),request,abi.encode(uint256(32),(type(uint64).max/32)-i));
                compare(abi.encodeCall(sol.getFeeGrowthInside,(PoolId.wrap(id),int24(0),int24(1))));
            }
        }
        vm.clearMockedCalls();
    }

}
