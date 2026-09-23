// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {SVG} from "./periphery/src/libraries/SVG.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract SvgReference {
    function generate(uint256 id,address hooks,int24 lower,int24 upper,int24 spacing,int8 range,string memory value) external pure returns(string memory){
        return SVG.generateSVG(SVG.SVGParams({quoteCurrency:value,baseCurrency:value,hooks:hooks,quoteCurrencySymbol:value,baseCurrencySymbol:value,feeTier:value,tickLower:lower,tickUpper:upper,tickSpacing:spacing,overRange:range,tokenId:id,color0:value,color1:value,color2:value,color3:value,x1:value,y1:value,x2:value,y2:value,x3:value,y3:value}));
    }
    function curve(int24 lower,int24 upper,int24 spacing) external pure returns(string memory){return SVG.getCurve(lower,upper,spacing);}
    function rare(uint256 id,address hooks) external pure returns(bool){return SVG.isRare(id,hooks);}
    function substring(string memory value,uint256 start,uint256 end) external pure returns(string memory){return SVG.substring(value,start,end);}
}
contract SvgParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SvgReference sol;
    function setUp() public {bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address a;assembly("memory-safe"){a:=create(0,add(code,32),mload(code))}require(a.code.length>0);fe=a;sol=new SvgReference();}
    function compare(bytes memory data) internal view {(bool a,bytes memory x)=fe.staticcall(data);(bool b,bytes memory y)=address(sol).staticcall(data);require(a==b&&keccak256(x)==keccak256(y),"SVG parity");}
    function testFuzz_generate(uint256 id,address hooks,int24 lower,int24 upper,int24 spacing,int8 range,string memory value) public view {
        compare(abi.encodeCall(sol.generate,(id,hooks,lower,upper,spacing,range,value)));
        compare(abi.encodeCall(sol.generate,((id%1e18)+1,hooks,int24(int256(lower)%887273),int24(int256(upper)%887273),60,int8(int256(range)%2),value)));
    }
    function testFuzz_helpers(uint256 id,address hooks,int24 lower,int24 upper,int24 spacing,string memory value,uint8 start,uint8 end) public view {
        compare(abi.encodeCall(sol.rare,(id,hooks)));compare(abi.encodeCall(sol.curve,(lower,upper,spacing)));compare(abi.encodeCall(sol.substring,(value,uint256(start),uint256(end))));
    }
    function test_boundaries() public view {
        for(uint256 i=1;i<=16;i++)compare(abi.encodeCall(sol.generate,(i,address(0),int24(-887272),int24(887272),1,int8(int256(i)%3-1),"ABC")));
        compare(abi.encodeCall(sol.rare,(uint256(0),address(0))));compare(abi.encodeCall(sol.rare,(uint256(1)<<127,address(0))));compare(abi.encodeCall(sol.rare,(uint256(1)<<128,address(0))));
        compare(abi.encodeCall(sol.substring,("",uint256(255),uint256(255))));
    }
}
