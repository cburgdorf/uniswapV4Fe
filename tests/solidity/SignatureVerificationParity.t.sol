// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SignatureVerification} from "./permit2/src/libraries/SignatureVerification.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function sign(uint256,bytes32) external pure returns(uint8,bytes32,bytes32);
    function addr(uint256) external pure returns(address);
}
contract SoliditySignatureVerification {
    function verify(bytes calldata signature,bytes32 hash,address owner) external view returns(bool) {
        SignatureVerification.verify(signature,hash,owner);return true;
    }
}
contract ContractSigner {
    uint256 public mode;
    function configure(uint256 m) external {mode=m;}
    fallback() external {
        uint256 m=mode;
        if(m==2)revert("1271 rejection");
        if(m==7){mode=9;return;}
        assembly {
            mstore(0,shl(224,0x1626ba7e))
            switch m
            case 1 {mstore(0,0)}
            case 3 {return(0,4)}
            case 4 {mstore(0,or(mload(0),1))}
            case 5 {return(0,10000)}
            case 6 {return(0,31)}
            return(0,32)
        }
    }
}
contract SignatureVerificationParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 constant N=0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    address fe;SoliditySignatureVerification sol;ContractSigner signer;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;
        sol=new SoliditySignatureVerification();signer=new ContractSigner();
    }
    function compare(bytes memory data) internal view returns(bool ok,bytes memory out) {
        (ok,out)=fe.staticcall{gas:1000000}(data);(bool refOk,bytes memory expected)=address(sol).staticcall{gas:1000000}(data);
        require(ok==refOk,"signature status mismatch");require(keccak256(out)==keccak256(expected),"signature revert/result mismatch");
    }
    function testFuzz_signed(uint256 privateSeed,bytes32 hash,bool compact,bool highS) public view {
        uint256 key=privateSeed%(N-1)+1;address owner=vm.addr(key);(uint8 v,bytes32 r,bytes32 s)=vm.sign(key,hash);
        bytes memory signature=compact?abi.encodePacked(r,bytes32(uint256(s)|(uint256(v-27)<<255))):abi.encodePacked(r,s,v);
        if(highS&&!compact)signature=abi.encodePacked(r,bytes32(N-uint256(s)),uint8(v==27?28:27));
        (bool ok,)=compare(abi.encodeCall(sol.verify,(signature,hash,owner)));require(ok,"valid signature including high-s raw form");
        (ok,)=compare(abi.encodeCall(sol.verify,(signature,hash,address(uint160(owner)^1))));require(!ok,"wrong signer");
    }
    function testFuzz_invalid(bytes32 hash,bytes32 r,bytes32 s,uint8 v,uint8 length) public view {
        bytes memory data=abi.encodePacked(r,s,v);uint256 len=uint256(length)%66;assembly {mstore(data,len)}
        compare(abi.encodeCall(sol.verify,(data,hash,address(123))));
        compare(abi.encodeCall(sol.verify,(data,hash,address(0))));
    }
    function testFuzz_contract(bytes memory signature,bytes32 hash,uint8 mode) public {
        signer.configure(mode%8);compare(abi.encodeCall(sol.verify,(signature,hash,address(signer))));
        require(signer.mode()==mode%8,"1271 must be static");
    }
    function test_unpaddedValidSignature() public view {
        bytes32 hash=keccak256("unpadded");(uint8 v,bytes32 r,bytes32 s)=vm.sign(1,hash);
        bytes memory data=abi.encodeCall(sol.verify,(abi.encodePacked(r,s,v),hash,vm.addr(1)));
        assembly {mstore(data,197)}
        (bool ok,)=compare(data);require(ok,"complete signature without ABI padding");
    }
}
