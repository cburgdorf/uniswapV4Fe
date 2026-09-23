// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolInitializer_v4} from "./periphery/src/base/PoolInitializer_v4.sol";
import {ImmutableState} from "./periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
}
contract SolidityPoolInitializer is PoolInitializer_v4 {
    constructor(address manager) ImmutableState(IPoolManager(manager)) {}
}
contract InitializerManager {
    uint256 mode;int24 tick;
    bytes public args;uint256 public calls;
    function configure(uint256 m,int24 t) external {mode=m;tick=t;}
    fallback() external {
        args=msg.data;calls++;
        uint256 m=mode;int256 t=tick;
        if(m==1)revert("initialize rejected");
        assembly {
            mstore(0,t)
            switch m
            case 2 {return(0,31)}
            case 3 {mstore(0,0x1000000)}
            case 4 {return(0,4096)}
            case 5 {return(0,0)}
            return(0,32)
        }
    }
}
contract PoolInitializerParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityPoolInitializer sol;InitializerManager manager;
    function deploy(address m) internal {
        bytes memory code=abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(m));address f;
        assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;sol=new SolidityPoolInitializer(m);
    }
    function setUp() public {manager=new InitializerManager();deploy(address(manager));vm.deal(address(this),100 ether);}
    function compare(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out){
        (ok,out)=fe.call{value:value}(data);(bool refOk,bytes memory expected)=address(sol).call{value:value}(data);
        require(ok==refOk,"initialize status");require(keccak256(out)==keccak256(expected),"initialize result");require(fe.balance==address(sol).balance,"value rollback");
    }
    function testFuzz_initialize(address a,address b,uint24 fee,int24 spacing,address hook,uint160 price,int24 tick,uint8 mode,uint64 value) public {
        uint256 m=mode%6;manager.configure(m,tick);
        PoolKey memory key=PoolKey(Currency.wrap(a),Currency.wrap(b),fee,spacing,IHooks(hook));
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.initializePool,(key,price)),uint256(value)%1 ether);
        require(ok==(m==0||m==1||m==4),"try/catch boundary");
        if(ok)require(abi.decode(out,(int24))==(m==1?type(int24).max:tick),"tick/sentinel");
        require(manager.calls()==(m==0||m==4?2:0),"callee rollback");
        if(m==0||m==4)require(keccak256(manager.args())==keccak256(abi.encodeCall(IPoolManager.initialize,(key,price))),"calldata");
        require(address(manager).balance==0,"value not forwarded");
    }
    function test_noCodeAndDirtyArguments() public {
        PoolKey memory key=PoolKey(Currency.wrap(address(1)),Currency.wrap(address(2)),3000,60,IHooks(address(0)));
        bytes memory data=abi.encodeCall(sol.initializePool,(key,uint160(1<<96)));
        deploy(address(123));(bool ok,)=compare(data,1);require(!ok,"successful empty return not caught");
        deploy(address(manager));assembly {mstore(add(data,36),shl(160,1))}
        (ok,)=compare(data,0);require(!ok,"dirty address");require(manager.calls()==0);
    }
}
