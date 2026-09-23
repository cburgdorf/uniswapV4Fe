// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {LiquidityAmounts} from "./periphery/src/libraries/LiquidityAmounts.sol";
import {SlippageCheck} from "./periphery/src/libraries/SlippageCheck.sol";
import {BipsLibrary} from "./periphery/src/libraries/BipsLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
}
contract SolidityPeripheryMath {
    function liquidity0(uint160 a,uint160 b,uint256 amount) external pure returns(uint128) {return LiquidityAmounts.getLiquidityForAmount0(a,b,amount);}
    function liquidity1(uint160 a,uint160 b,uint256 amount) external pure returns(uint128) {return LiquidityAmounts.getLiquidityForAmount1(a,b,amount);}
    function liquidity(uint160 price,uint160 a,uint160 b,uint256 amount0,uint256 amount1) external pure returns(uint128) {return LiquidityAmounts.getLiquidityForAmounts(price,a,b,amount0,amount1);}
    function slippage(int256 delta,uint128 a,uint128 b,bool minimum) external pure {
        if(minimum) SlippageCheck.validateMinOut(BalanceDelta.wrap(delta),a,b);
        else SlippageCheck.validateMaxIn(BalanceDelta.wrap(delta),a,b);
    }
    function portion(uint256 amount,uint256 bips) external pure returns(uint256) {return BipsLibrary.calculatePortion(amount,bips);}
}
contract PeripheryMathParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityPeripheryMath sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address deployed;
        assembly {deployed:=create(0,add(code,32),mload(code))}
        require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityPeripheryMath();
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall(data);(bool other,bytes memory expected)=address(sol).staticcall(data);
        require(ok==other,"status mismatch");require(keccak256(out)==keccak256(expected),"return/revert mismatch");
    }
    function testFuzz_liquidity(uint160 price,uint160 a,uint160 b,uint256 amount0,uint256 amount1) public view {
        compare(abi.encodeCall(sol.liquidity0,(a,b,amount0)));
        compare(abi.encodeCall(sol.liquidity1,(a,b,amount1)));
        compare(abi.encodeCall(sol.liquidity,(price,a,b,amount0,amount1)));
    }
    function testFuzz_slippage(int256 delta,uint128 a,uint128 b,bool minimum) public view {compare(abi.encodeCall(sol.slippage,(delta,a,b,minimum)));}
    function testFuzz_portion(uint256 amount,uint256 bips) public view {
        compare(abi.encodeCall(sol.portion,(amount,bips)));
        compare(abi.encodeCall(sol.portion,(amount,bips%10001)));
    }
    function test_boundaries() public view {
        compare(abi.encodeCall(sol.liquidity0,(0,0,0)));
        compare(abi.encodeCall(sol.liquidity1,(0,0,0)));
        compare(abi.encodeCall(sol.liquidity,(1,1,1,0,0)));
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.liquidity,(uint160(1<<96),uint160(1<<95),uint160(2<<96),100,100)));
        require(ok && abi.decode(out,(uint128))==200,"interior liquidity model");
        (ok,out)=compare(abi.encodeCall(sol.portion,(10000,10000)));require(ok && abi.decode(out,(uint256))==10000,"full portion");
        compare(abi.encodeCall(sol.portion,(type(uint256).max,10000)));
        compare(abi.encodeCall(sol.slippage,(type(int256).min,0,0,true)));
        compare(abi.encodeCall(sol.slippage,(type(int256).min,type(uint128).max,type(uint128).max,false)));
        compare(abi.encodeCall(sol.slippage,(type(int256).min,0,0,false)));
    }
}
