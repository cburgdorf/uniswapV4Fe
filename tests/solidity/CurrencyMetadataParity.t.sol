// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {SafeCurrencyMetadata} from "./periphery/src/libraries/SafeCurrencyMetadata.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract MetadataProvider {
    bytes symbolData;bytes decimalsData;bool symbolFail;bool decimalsFail;
    function configure(bytes memory a,bytes memory b,bool c,bool d) external {symbolData=a;decimalsData=b;symbolFail=c;decimalsFail=d;}
    fallback() external {
        bool symbol=msg.sig==bytes4(keccak256("symbol()"));bytes memory data=symbol?symbolData:decimalsData;bool fail=symbol?symbolFail:decimalsFail;
        assembly("memory-safe"){if fail {revert(add(data,32),mload(data))}return(add(data,32),mload(data))}
    }
}
contract MetadataReference {
    function symbol(address token,string memory label) external view returns(string memory){return SafeCurrencyMetadata.currencySymbol(token,label);}
    function decimals(address token) external view returns(uint8){return SafeCurrencyMetadata.currencyDecimals(token);}
    function truncate(string memory value) external pure returns(string memory){return SafeCurrencyMetadata.truncateSymbol(value);}
}
contract CurrencyMetadataParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;MetadataReference sol;MetadataProvider provider;
    function setUp() public {bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address a;assembly("memory-safe"){a:=create(0,add(code,32),mload(code))}require(a.code.length>0);fe=a;sol=new MetadataReference();provider=new MetadataProvider();}
    function compare(bytes memory data) internal view {(bool a,bytes memory x)=fe.staticcall(data);(bool b,bytes memory y)=address(sol).staticcall(data);require(a==b&&keccak256(x)==keccak256(y),"metadata parity");}
    function testFuzz_rawReturns(bytes memory symbolData,bytes memory decimalsData,bool symbolFail,bool decimalsFail) public {
        provider.configure(symbolData,decimalsData,symbolFail,decimalsFail);
        compare(abi.encodeCall(sol.symbol,(address(provider),"native")));compare(abi.encodeCall(sol.decimals,(address(provider))));
    }
    function testFuzz_canonical(string memory symbol,uint256 decimals,bytes32 fixedSymbol,bool unpadded) public {
        bytes memory data=abi.encode(symbol);if(unpadded){uint256 len=64+bytes(symbol).length;assembly("memory-safe"){mstore(data,len)}}
        provider.configure(data,abi.encode(decimals),false,false);
        compare(abi.encodeCall(sol.symbol,(address(provider),"native")));compare(abi.encodeCall(sol.decimals,(address(provider))));
        provider.configure(abi.encode(fixedSymbol),abi.encode(decimals%256),false,false);
        compare(abi.encodeCall(sol.symbol,(address(provider),"native")));compare(abi.encodeCall(sol.decimals,(address(provider))));
        compare(abi.encodeCall(sol.symbol,(address(0),symbol)));compare(abi.encodeCall(sol.truncate,(symbol)));
    }
    function test_lengthsAndOffsets() public {
        compare(abi.encodeCall(sol.symbol,(address(0x1234),"native")));compare(abi.encodeCall(sol.decimals,(address(0x1234))));compare(abi.encodeCall(sol.decimals,(address(0))));
        for(uint256 len=0;len<100;len++){bytes memory data=new bytes(len);provider.configure(data,data,false,false);compare(abi.encodeCall(sol.symbol,(address(provider),"native")));compare(abi.encodeCall(sol.decimals,(address(provider))));}
        bytes memory unaligned=bytes.concat(bytes32(uint256(33)),hex"00",bytes32(uint256(3)),bytes("ABC"));
        provider.configure(unaligned,"",false,false);compare(abi.encodeCall(sol.symbol,(address(provider),"")));
    }
}
