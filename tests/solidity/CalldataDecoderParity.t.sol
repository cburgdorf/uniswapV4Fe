// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {CalldataDecoder} from "./periphery/src/libraries/CalldataDecoder.sol";
import {IV4Router} from "./periphery/src/interfaces/IV4Router.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);}
contract SolidityCalldataDecoder {
    using CalldataDecoder for bytes;
    function slice(bytes calldata data,uint256 arg) external pure returns(bytes memory) {return data.toBytes(arg);}
    function actions(bytes calldata data) external pure returns(bytes memory) { (bytes calldata a,bytes[] calldata p)=data.decodeActionsRouterParams();return abi.encode(a,p); }
    function decode(bytes calldata data,uint8 mode) external pure returns(bytes memory) {
        if(mode==0) { Currency v0=data.decodeCurrency();return abi.encode(v0); }
        if(mode==1) { (Currency v0, Currency v1)=data.decodeCurrencyPair();return abi.encode(v0,v1); }
        if(mode==2) { (Currency v0, Currency v1, address v2)=data.decodeCurrencyPairAndAddress();return abi.encode(v0,v1,v2); }
        if(mode==3) { (Currency v0, address v1)=data.decodeCurrencyAndAddress();return abi.encode(v0,v1); }
        if(mode==4) { (Currency v0, address v1, uint256 v2)=data.decodeCurrencyAddressAndUint256();return abi.encode(v0,v1,v2); }
        if(mode==5) { (Currency v0, uint256 v1)=data.decodeCurrencyAndUint256();return abi.encode(v0,v1); }
        if(mode==6) { uint256 v0=data.decodeUint256();return abi.encode(v0); }
        if(mode==7) { (Currency v0, uint256 v1, bool v2)=data.decodeCurrencyUint256AndBool();return abi.encode(v0,v1,v2); }
        if(mode==8) { (uint256 v0, uint256 v1, uint128 v2, uint128 v3, bytes calldata v4)=data.decodeModifyLiquidityParams();return abi.encode(v0,v1,v2,v3,v4); }
        if(mode==9) { (uint256 v0, uint128 v1, uint128 v2, bytes calldata v3)=data.decodeIncreaseLiquidityFromDeltasParams();return abi.encode(v0,v1,v2,v3); }
        if(mode==10) { (PoolKey calldata v0, int24 v1, int24 v2, uint256 v3, uint128 v4, uint128 v5, address v6, bytes calldata v7)=data.decodeMintParams();return abi.encode(v0,v1,v2,v3,v4,v5,v6,v7); }
        if(mode==11) { (PoolKey calldata v0, int24 v1, int24 v2, uint128 v3, uint128 v4, address v5, bytes calldata v6)=data.decodeMintFromDeltasParams();return abi.encode(v0,v1,v2,v3,v4,v5,v6); }
        if(mode==12) { (uint256 v0, uint128 v1, uint128 v2, bytes calldata v3)=data.decodeBurnParams();return abi.encode(v0,v1,v2,v3); }
        if(mode==13) { IV4Router.ExactInputSingleParams calldata p=data.decodeSwapExactInSingleParams();uint256 offset;assembly {offset:=sub(p,data.offset)} return abi.encode(offset); }
        if(mode==14) { IV4Router.ExactInputParams calldata p=data.decodeSwapExactInParams();uint256 offset;assembly {offset:=sub(p,data.offset)} return abi.encode(offset); }
        if(mode==15) { IV4Router.ExactOutputSingleParams calldata p=data.decodeSwapExactOutSingleParams();uint256 offset;assembly {offset:=sub(p,data.offset)} return abi.encode(offset); }
        { IV4Router.ExactOutputParams calldata p=data.decodeSwapExactOutParams();uint256 offset;assembly {offset:=sub(p,data.offset)} return abi.encode(offset); }
    }
}
contract CalldataDecoderParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityCalldataDecoder sol;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address deployed;
        assembly {deployed:=create(0,add(code,32),mload(code))}require(deployed.code.length>0,"Fe deploy");fe=deployed;sol=new SolidityCalldataDecoder();
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall{gas:500000}(data);(bool other,bytes memory expected)=address(sol).staticcall{gas:500000}(data);
        require(ok==other,"decoder status mismatch");require(keccak256(out)==keccak256(expected),"decoder bytes mismatch");
    }
    function testFuzz_raw(bytes memory data,uint8 mode,uint256 arg) public view {
        compare(abi.encodeCall(sol.decode,(data,mode%17)));
        compare(abi.encodeCall(sol.slice,(data,arg)));
    }
    function testFuzz_primitives(uint256 a,uint256 b,uint256 c,uint8 mode) public view {
        (bool ok,)=compare(abi.encodeCall(sol.decode,(abi.encode(a,b,c),mode%8)));require(ok,"primitive valid length");
    }
    function testFuzz_liquidity(uint256 tokenId,uint256 liquidity,uint256 a,uint256 b,bytes memory hookData) public view {
        compare(abi.encodeCall(sol.decode,(abi.encode(tokenId,liquidity,a,b,hookData),uint8(8))));
        compare(abi.encodeCall(sol.decode,(abi.encode(tokenId,a,b,hookData),uint8(9))));
        compare(abi.encodeCall(sol.decode,(abi.encode(tokenId,a,b,hookData),uint8(12))));
    }
    function testFuzz_mint(address owner,int24 lower,int24 upper,uint256 amount,bytes memory hookData,uint256 dirty,uint8 index) public view {
        PoolKey memory key=PoolKey(Currency.wrap(address(123)),Currency.wrap(address(456)),3000,60,IHooks(address(0)));
        bytes memory data=abi.encode(key,lower,upper,amount,uint256(17),uint256(19),owner,hookData);
        (bool ok,)=compare(abi.encodeCall(sol.decode,(data,uint8(10))));require(ok,"canonical mint");
        uint256 at=uint256(index)%11;assembly {mstore(add(add(data,32),mul(at,32)),dirty)}
        compare(abi.encodeCall(sol.decode,(data,uint8(10))));
        data=abi.encode(key,lower,upper,uint256(17),uint256(19),owner,hookData);
        (ok,)=compare(abi.encodeCall(sol.decode,(data,uint8(11))));require(ok,"mint from deltas");
    }
    function testFuzz_actions(bytes memory a,bytes memory x,bytes memory y,bytes memory z,uint8 mutation) public view {
        bytes[] memory params=new bytes[](3);params[0]=x;params[1]=y;params[2]=z;
        bytes memory data=abi.encode(a,params);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.actions,(data)));require(ok,"canonical actions");
        require(keccak256(abi.decode(out,(bytes)))==keccak256(data),"action reencoding");
        uint256 mode=mutation%4;
        assembly {
            let ptr:=add(data,32)
            switch mode
            case 0 {mstore(ptr,0)}
            case 1 {mstore(add(ptr,64),or(mload(add(ptr,64)),shl(32,1)))}
            case 2 {let p:=add(ptr,mload(add(ptr,32))) mstore(p,or(mload(p),shl(32,1)))}
            case 3 {let p:=add(add(ptr,mload(add(ptr,32))),32) let tail:=add(p,mload(p)) mstore(tail,or(mload(tail),shl(32,1)))}
        }
        compare(abi.encodeCall(sol.actions,(data)));
    }
    function test_lengthsAndOffsetMasks() public view {
        for(uint256 length=0;length<385;length++) {
            bytes memory data=new bytes(length);
            for(uint8 mode=0;mode<17;mode++) compare(abi.encodeCall(sol.decode,(data,mode)));
        }
        bytes memory inner=abi.encode(uint256(32),uint256(3));inner=bytes.concat(inner,hex"112233");
        (bool ok,)=compare(abi.encodeCall(sol.slice,(inner,uint256(0))));require(ok,"unpadded slice");
        assembly {mstore(add(inner,32),or(32,shl(32,1))) mstore(add(inner,64),or(3,shl(32,1)))}
        (ok,)=compare(abi.encodeCall(sol.slice,(inner,uint256(0))));require(ok,"masked slice offset and length");
        bytes[] memory none=new bytes[](0);compare(abi.encodeCall(sol.actions,(abi.encode(bytes(""),none))));
    }
}
