// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {NativeWrapper} from "./periphery/src/base/NativeWrapper.sol";
import {IWETH9} from "./periphery/src/interfaces/external/IWETH9.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function prank(address) external;
}
contract SolidityNativeWrapper is NativeWrapper {
    constructor(address weth,address manager) NativeWrapper(IWETH9(weth)) ImmutableState(IPoolManager(manager)) {}
    function wrap(uint256 amount) external payable {_wrap(amount);}
    function unwrap(uint256 amount) external {_unwrap(amount);}
}
import {ImmutableState} from "./periphery/src/base/ImmutableState.sol";
contract WrappedToken {
    mapping(address=>uint256) public balanceOf;
    bool public reject;
    uint256 public deposits;
    uint256 public withdrawals;
    function configure(bool value) external {reject=value;}
    function deposit() external payable {require(!reject,"deposit rejected");deposits++;balanceOf[msg.sender]+=msg.value;}
    function withdraw(uint256 amount) external {require(!reject,"withdraw rejected");withdrawals++;balanceOf[msg.sender]-=amount;(bool ok,)=msg.sender.call{value:amount}("");require(ok,"return native");}
}
contract NativeWrapperParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityNativeWrapper sol;WrappedToken token;
    address constant MANAGER=address(0xcafe);
    function deploy(address weth) internal {
        bytes memory code=abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(weth,MANAGER));address f;
        assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;sol=new SolidityNativeWrapper(weth,MANAGER);
    }
    function setUp() public {token=new WrappedToken();deploy(address(token));vm.deal(address(this),100 ether);}
    function compare(bytes memory data,address caller,uint256 value) internal returns(bool ok){
        vm.deal(caller,10 ether);vm.prank(caller);bytes memory out;(ok,out)=fe.call{value:value}(data);
        vm.prank(caller);(bool refOk,bytes memory expected)=address(sol).call{value:value}(data);
        require(ok==refOk,"wrapper status");require(keccak256(out)==keccak256(expected),"wrapper result");
        require(fe.balance==address(sol).balance,"native balances");require(token.balanceOf(fe)==token.balanceOf(address(sol)),"wrapped balances");
    }
    function testFuzz_wrapAndUnwrap(uint64 value,uint64 unwrapAmount,bool reject) public {
        uint256 n=uint256(value)%1 ether;uint256 u=uint256(unwrapAmount)%(n+2);token.configure(reject);
        compare(abi.encodeCall(sol.wrap,(n)),address(this),n);
        token.configure(false);compare(abi.encodeCall(sol.unwrap,(u)),address(this),0);
    }
    function testFuzz_receive(uint64 value,uint8 sender,bool nonempty) public {
        address caller=sender%3==0?MANAGER:sender%3==1?address(token):address(123);
        bool ok=compare(nonempty?bytes(hex"12345678"):bytes(""),caller,uint256(value)%1 ether);
        require(ok==(!nonempty&&sender%3!=2),"receive authorization");
    }
    function test_zeroAndNoCode() public {
        token.configure(true);require(compare(abi.encodeCall(sol.wrap,(0)),address(this),1));
        require(compare(abi.encodeCall(sol.unwrap,(0)),address(this),0));require(token.deposits()==0&&token.withdrawals()==0);
        deploy(address(123));require(compare(abi.encodeCall(sol.wrap,(0)),address(this),0));
        require(!compare(abi.encodeCall(sol.wrap,(1)),address(this),1));require(!compare(abi.encodeCall(sol.unwrap,(1)),address(this),0));
    }
}
