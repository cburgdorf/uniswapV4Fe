// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {V4Quoter} from "./periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "./periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "./periphery/src/libraries/PathKey.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {SwapParams} from "./reference/src/types/PoolOperation.sol";
import {BalanceDelta,toBalanceDelta} from "./reference/src/types/BalanceDelta.sol";
interface Vm {function readFile(string calldata) external view returns(string memory);function parseBytes(string calldata) external pure returns(bytes memory);function prank(address) external;}
interface ICallback {function unlockCallback(bytes calldata) external returns(bytes memory);}
contract QuoteManager {
    address immutable owner=msg.sender;
    bytes public rawReason;
    function setReason(bytes memory reason) external {rawReason=reason;mode=4;}
    int128 public input;int128 public output;uint256 public swaps;uint8 public mode;
    function configure(int128 a,int128 b,uint8 m) external {input=a;output=b;mode=m;}
    function unlock(bytes calldata data) external returns(bytes memory) {
        if(mode==4){bytes memory reason=rawReason;assembly {revert(add(reason,32),mload(reason))}}
        if(mode==1)return "";
        if(mode==2)revert("manager rejects");
        return ICallback(msg.sender).unlockCallback(data);
    }
    function swap(PoolKey calldata,SwapParams calldata p,bytes calldata) external returns(BalanceDelta) {
        if(mode==5) {
            require(IV4Quoter(msg.sender).msgSender()==owner,"outer sender marker");
            mode=1;
            IV4Quoter.QuoteExactParams memory empty=IV4Quoter.QuoteExactParams(Currency.wrap(address(0)),new PathKey[](0),0);
            IV4Quoter(msg.sender).quoteExactInput(empty);
            require(IV4Quoter(msg.sender).msgSender()==address(0),"nested quote clears sender marker");
            mode=5;
        }
        swaps++;
        int128 a=input;int128 b=output;
        if(mode==3){if(p.amountSpecified<0)a=int128(p.amountSpecified);else b=int128(p.amountSpecified);}
        return p.zeroForOne?toBalanceDelta(a,b):toBalanceDelta(b,a);
    }
}
contract QuoterParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;V4Quoter sol;QuoteManager manager;
    function setUp() public {
        manager=new QuoteManager();bytes memory code=bytes.concat(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(address(manager)));
        address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;sol=new V4Quoter(IPoolManager(address(manager)));
    }
    function key() internal pure returns(PoolKey memory) {return PoolKey(Currency.wrap(address(10)),Currency.wrap(address(20)),3000,60,IHooks(address(0)));}
    function compare(bytes memory data,bool quote) internal returns(bool ok,bytes memory out) {
        uint256 beforeGas=gasleft();(ok,out)=fe.call(data);uint256 spent=beforeGas-gasleft();
        (bool other,bytes memory expected)=address(sol).call(data);require(ok==other,"quoter status mismatch");
        if(ok&&quote) {
            (uint256 amount,uint256 estimated)=abi.decode(out,(uint256,uint256));(uint256 refAmount,uint256 refGas)=abi.decode(expected,(uint256,uint256));
            require(amount==refAmount,"quote amount mismatch");
            require(estimated<=spent,"measured gas bounded by whole call");
            require((estimated==0)==(refGas==0),"gas estimate zero/nonzero");
        } else require(keccak256(out)==keccak256(expected),"quoter bytes mismatch");
        require(manager.swaps()==0,"quote rollback");
        require(IV4Quoter(fe).msgSender()==address(0)&&sol.msgSender()==address(0),"sender reset");
    }
    function testFuzz_single(uint128 amount,int128 paid,int128 received,bool exactOut,bool direction,bytes memory hook) public {
        manager.configure(paid,received,0);
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),direction,amount,hook);
        compare(exactOut?abi.encodeCall(sol.quoteExactOutputSingle,(p)):abi.encodeCall(sol.quoteExactInputSingle,(p)),true);
    }
    function testFuzz_multi(uint128 amount,int128 paid,int128 received,bool exactOut,uint8 count,bytes memory hook) public {
        manager.configure(paid,received,0);PathKey[] memory path=new PathKey[](count%4);
        for(uint256 i;i<path.length;i++)path[i]=PathKey(Currency.wrap(address(uint160(20+i*10))),3000,60,IHooks(address(0)),hook);
        IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),path,amount);
        compare(exactOut?abi.encodeCall(sol.quoteExactOutput,(p)):abi.encodeCall(sol.quoteExactInput,(p)),true);
    }
    function test_successAndCallerGuards() public {
        manager.configure(-7,11,0);
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,"");
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);require(ok&&abi.decode(out,(uint256))==11,"input quote");
        p.exactAmount=11;(ok,out)=compare(abi.encodeCall(sol.quoteExactOutputSingle,(p)),true);require(ok&&abi.decode(out,(uint256))==7,"output quote");
        compare(abi.encodeCall(sol._quoteExactInputSingle,(p)),false);
        compare(abi.encodeCall(sol.unlockCallback,(bytes(""))),false);
        manager.configure(-7,11,1);(ok,out)=compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);require(ok&&abi.decode(out,(uint256))==0,"unexpected manager success returns defaults");
        manager.configure(-7,11,2);compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);
    }
    function test_signAndWidthBoundaries() public {
        manager.configure(type(int128).min,0,0);
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,uint128(1)<<127,"");
        compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);
        manager.configure(type(int128).min,11,0);p.exactAmount=11;compare(abi.encodeCall(sol.quoteExactOutputSingle,(p)),true);
        manager.configure(-7,1,0);p.exactAmount=type(uint128).max;
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);
        require(ok&&abi.decode(out,(uint256))==1,"reference signed input cast");
    }
    function testFuzz_filledRoutes(uint64 amount,uint8 count,bool exactOut) public {
        manager.configure(-7,11,3);uint256 n=count%4;
        PathKey[] memory path=new PathKey[](n);
        for(uint256 i;i<n;i++)path[i]=PathKey(Currency.wrap(address(uint160(20+i*10))),3000,60,IHooks(address(0)),hex"1122");
        uint128 requested=uint128(amount)+1;
        IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),path,requested);
        (bool ok,bytes memory out)=compare(exactOut?abi.encodeCall(sol.quoteExactOutput,(p)):abi.encodeCall(sol.quoteExactInput,(p)),true);
        require(ok&&abi.decode(out,(uint256))==(n==0?requested:exactOut?7:11),"filled route quote model");
    }

    function test_internalAuthPrecedence() public {
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,"");
        bytes memory data=abi.encodeCall(sol._quoteExactInputSingle,(p));
        assembly {mstore(add(data,228),2)}
        compare(data,false);
    }

    function test_publicOversizedArray() public {
        IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),new PathKey[](0),7);
        bytes memory data=abi.encodeCall(sol.quoteExactInput,(p));
        assembly {mstore(add(data,164),not(0))}
        compare(data,true);
    }

    function test_publicAllocationBoundaries() public {
        uint256[7] memory lengths=[uint256(type(uint256).max),uint256(type(uint64).max)+1,uint256(type(uint64).max),uint256(type(uint64).max)-447,uint256(type(uint64).max)-479,uint256(type(uint64).max)/32-8,uint256(0)];
        for(uint256 i;i<lengths.length;i++) {
            IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,"");
            bytes memory data=abi.encodeCall(sol.quoteExactInputSingle,(p));
            uint256 length=lengths[i];
            assembly {mstore(add(data,324),length)}
            compare(data,true);
            // Dirty bool takes precedence over even an impossible bytes length.
            assembly {mstore(add(data,228),2)}
            compare(data,true);
            IV4Quoter.QuoteExactParams memory multi=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),new PathKey[](0),7);
            data=abi.encodeCall(sol.quoteExactOutput,(multi));
            assembly {mstore(add(data,164),length)}
            compare(data,true);
            // The amount is decoded after the path, so allocation wins here.
            assembly {mstore(add(data,132),not(0))}
            compare(data,true);
        }
        PathKey[] memory paths=new PathKey[](1);
        paths[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),"");
        IV4Quoter.QuoteExactParams memory m=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),paths,7);
        bytes memory nested=abi.encodeCall(sol.quoteExactInput,(m));
        assembly {mstore(add(nested,388),not(0))}
        compare(nested,true);
    }

    function testFuzz_publicMalformed(uint256 value,uint8 field,bool single,bool exactOut) public {
        bytes memory data;
        if(single) {
            IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,hex"1122");
            data=exactOut?abi.encodeCall(sol.quoteExactOutputSingle,(p)):abi.encodeCall(sol.quoteExactInputSingle,(p));
        } else {
            PathKey[] memory paths=new PathKey[](1);
            paths[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),hex"1122");
            IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),paths,7);
            data=exactOut?abi.encodeCall(sol.quoteExactOutput,(p)):abi.encodeCall(sol.quoteExactInput,(p));
        }
        uint256 offset=36+32*(uint256(field)%((data.length-4)/32));
        assembly {mstore(add(data,offset),value)}
        compare(data,true);
    }

    function test_shortQuoteReasons() public {
        bytes memory reason=abi.encodeWithSignature("QuoteSwap(uint256)",type(uint256).max);
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,"");
        bytes memory data=abi.encodeCall(sol.quoteExactInputSingle,(p));
        for(uint256 len;len<=36;len++) {
            bytes memory shortReason=new bytes(len);
            for(uint256 j;j<len;j++)shortReason[j]=reason[j];
            manager.setReason(shortReason);compare(data,true);
            compare(abi.encodeCall(sol.quoteExactOutputSingle,(p)),true);
            PathKey[] memory paths=new PathKey[](1);
            paths[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),hex"123456");
            IV4Quoter.QuoteExactParams memory multi=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),paths,7);
            compare(abi.encodeCall(sol.quoteExactInput,(multi)),true);
            compare(abi.encodeCall(sol.quoteExactOutput,(multi)),true);
        }
    }

    function test_truncatedPublicCalls() public {
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,hex"11223344");
        bytes memory single=abi.encodeCall(sol.quoteExactInputSingle,(p));
        PathKey[] memory paths=new PathKey[](1);
        paths[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),hex"123456");
        IV4Quoter.QuoteExactParams memory multi=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),paths,7);
        bytes memory route=abi.encodeCall(sol.quoteExactInput,(multi));
        for(uint256 len;len<route.length;len++) {
            bytes memory cut=new bytes(len);for(uint256 j;j<len;j++)cut[j]=route[j];compare(cut,true);
            if(len<single.length){cut=new bytes(len);for(uint256 j;j<len;j++)cut[j]=single[j];compare(cut,true);}
        }
    }
    function test_aliasPaths() public {
        PathKey[] memory paths=new PathKey[](2);
        paths[0]=PathKey(Currency.wrap(address(20)),3000,60,IHooks(address(0)),hex"123456");
        paths[1]=PathKey(Currency.wrap(address(30)),3000,60,IHooks(address(0)),hex"abcd");
        IV4Quoter.QuoteExactParams memory p=IV4Quoter.QuoteExactParams(Currency.wrap(address(10)),paths,7);
        bytes memory data=abi.encodeCall(sol.quoteExactInput,(p));
        // Both element pointers refer to the first PathKey.
        assembly {mstore(add(data,228),mload(add(data,196)))}
        compare(data,true);
        // Swap the original two element pointers (valid noncanonical tail order).
        data=abi.encodeCall(sol.quoteExactOutput,(p));
        assembly {let first:=mload(add(data,196)) mstore(add(data,196),mload(add(data,228))) mstore(add(data,228),first)}
        compare(data,true);
    }

    function test_reentrantSenderMarker() public {
        manager.configure(-7,11,5);
        IV4Quoter.QuoteExactSingleParams memory p=IV4Quoter.QuoteExactSingleParams(key(),true,7,"");
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.quoteExactInputSingle,(p)),true);
        require(ok&&abi.decode(out,(uint256))==11,"unlocked nested quote");
    }

    function testFuzz_publicSmallOffsets(uint16 value,uint8 field,bool single,bool exactOut) public {
        testFuzz_publicMalformed(uint256(value)%512,field,single,exactOut);
    }

}
