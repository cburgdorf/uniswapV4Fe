// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Descriptor} from "./periphery/src/libraries/Descriptor.sol";
import {HexStrings} from "./periphery/src/libraries/HexStrings.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract FormatReference {
    function fee(uint24 value) external pure returns(string memory){return Descriptor.feeToPercentString(value);}
    function price(uint160 sqrt,uint8 base,uint8 quote) external pure returns(string memory){return Descriptor.fixedPointToDecimalString(sqrt,base,quote);}
    function tick(int24 value,int24 spacing,uint8 base,uint8 quote,bool flip) external pure returns(string memory){return Descriptor.tickToDecimalString(value,spacing,base,quote,flip);}
    function escape(string memory value) external pure returns(string memory){return Descriptor.escapeSpecialCharacters(value);}
    function hexString(uint256 value,uint256 len) external pure returns(string memory){return HexStrings.toHexStringNoPrefix(value,len);}
    fallback(bytes calldata data) external returns(bytes memory){(uint256 value,uint256 len)=abi.decode(data[4:],(uint256,uint256));return abi.encode(HexStrings.toHexStringNoPrefix(value,len));}
    function decimal(uint256 value) external pure returns(string memory){return Strings.toString(value);}
    function base64(bytes memory value) external pure returns(string memory){return Base64.encode(value);}
}
contract DescriptorFormatParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;FormatReference sol;
    function setUp() public {bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address a;assembly("memory-safe"){a:=create(0,add(code,32),mload(code))}require(a.code.length>0);fe=a;sol=new FormatReference();}
    function compare(bytes memory data) internal view {(bool a,bytes memory x)=fe.staticcall(data);(bool b,bytes memory y)=address(sol).staticcall(data);require(a==b&&keccak256(x)==keccak256(y),"format parity");}
    function testFuzz_fee(uint24 value) public view {compare(abi.encodeCall(sol.fee,(value)));}
    function testFuzz_price(uint160 sqrt,uint8 base,uint8 quote) public view {compare(abi.encodeCall(sol.price,(sqrt,base,quote)));}
    function testFuzz_tick(int24 tick,int24 spacing,uint8 base,uint8 quote,bool flip) public view {compare(abi.encodeCall(sol.tick,(tick,spacing,base,quote,flip)));int24 valid=int24(int256(tick)%887273);compare(abi.encodeCall(sol.tick,(valid,60,base,quote,flip)));}
    function testFuzz_text(string memory value,uint256 number,uint8 len) public view {compare(abi.encodeCall(sol.escape,(value)));compare(abi.encodeCall(sol.base64,(bytes(value))));compare(abi.encodeCall(sol.decimal,(number)));compare(abi.encodeWithSignature("hex(uint256,uint256)",number,uint256(len)%65));}
    function test_boundaries() public view {
        uint24[9] memory fees=[uint24(0),1,100,3000,10000,99999,1000000,0x800000,0xffffff];for(uint256 i;i<fees.length;i++)compare(abi.encodeCall(sol.fee,(fees[i])));
        for(uint256 i;i<40;i++)compare(abi.encodeCall(sol.price,(uint160(79228162514264337593543950336),uint8(i),uint8(18))));
        compare(abi.encodeCall(sol.escape,(string(new bytes(255)))));compare(abi.encodeCall(sol.escape,(string(new bytes(256)))));compare(abi.encodeCall(sol.escape,(string(hex"220c0a0d095c"))));
        compare(abi.encodeCall(sol.tick,(int24(-887272),int24(1),18,18,false)));compare(abi.encodeCall(sol.tick,(int24(887272),int24(1),18,18,true)));
    }
}
