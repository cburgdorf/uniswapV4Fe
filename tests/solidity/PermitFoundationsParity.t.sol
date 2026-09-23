// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {EIP712_v4} from "./periphery/src/base/EIP712_v4.sol";
import {UnorderedNonce} from "./periphery/src/base/UnorderedNonce.sol";
import {ERC721PermitHash} from "./periphery/src/libraries/ERC721PermitHash.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function load(address,bytes32) external view returns(bytes32);
    function chainId(uint256) external;
    function deal(address,uint256) external;
}
contract SolidityPermitFoundations is EIP712_v4,UnorderedNonce {
    constructor(bytes memory name) EIP712_v4(string(name)) {}
    function consume(address owner,uint256 nonce) external {_useUnorderedNonce(owner,nonce);}
    function digest(bytes32 value) external view returns(bytes32) {return _hashTypedData(value);}
    function hashPermit(address spender,uint256 token,uint256 nonce,uint256 deadline) external pure returns(bytes32) {return ERC721PermitHash.hashPermit(spender,token,nonce,deadline);}
    function hashPermitForAll(address operator,bool approved,uint256 nonce,uint256 deadline) external pure returns(bytes32) {return ERC721PermitHash.hashPermitForAll(operator,approved,nonce,deadline);}
}
contract DomainRelay {
    function invoke(address target,bytes memory data) external returns(bytes memory out) {
        bool ok;(ok,out)=target.delegatecall(data);if(!ok)assembly {revert(add(out,32),mload(out))}
    }
}
contract PermitFoundationsParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes code;address fe;SolidityPermitFoundations sol;
    bytes32 constant DOMAIN_TYPE=keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    function deploy(bytes memory name) internal returns(address result) {
        bytes memory creation=bytes.concat(code,abi.encode(name));assembly {result:=create(0,add(creation,32),mload(creation))}require(result.code.length>0,"Fe deploy");
    }
    function setUp() public {
        code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));fe=deploy("Uniswap v4 Positions NFT");sol=new SolidityPermitFoundations("Uniswap v4 Positions NFT");vm.deal(address(this),1e20);
    }
    function compare(bytes memory data,uint256 value) internal returns(bool ok,bytes memory out) {
        (ok,out)=fe.call{value:value}(data);(bool refOk,bytes memory expected)=address(sol).call{value:value}(data);
        require(ok==refOk,"permit foundation status");require(keccak256(out)==keccak256(expected),"permit foundation bytes");
    }
    function bitmap(address owner,uint256 word) internal view returns(bytes32) {
        bytes32 slot=keccak256(abi.encode(word,keccak256(abi.encode(owner,uint256(0)))));
        bytes32 a=vm.load(fe,slot);require(a==vm.load(address(sol),slot),"nonce raw slot parity");return a;
    }
    function testFuzz_hashes(address account,uint256 token,uint256 nonce,uint256 deadline,bool approved) public {
        compare(abi.encodeCall(sol.hashPermit,(account,token,nonce,deadline)),0);
        compare(abi.encodeCall(sol.hashPermitForAll,(account,approved,nonce,deadline)),0);
    }
    function testFuzz_nonces(address owner,uint256 nonce,uint8 sibling) public {
        bytes memory data=abi.encodeCall(sol.consume,(owner,nonce));(bool ok,)=compare(data,0);require(ok,"first nonce use");
        uint256 expected=uint256(1)<<uint8(nonce);require(uint256(bitmap(owner,nonce>>8))==expected,"nonce bitmap model");
        (ok,)=compare(data,0);require(!ok&&uint256(bitmap(owner,nonce>>8))==expected,"replay rolled back");
        uint256 other=(nonce&~uint256(255))|uint256(sibling);
        (ok,)=compare(abi.encodeCall(sol.consume,(owner,other)),0);require(ok==(other!=nonce),"sibling independence");
        compare(abi.encodeCall(sol.nonces,(owner,nonce>>8)),0);bitmap(owner,nonce>>8);
    }
    // Capture the chain id across an external boundary: solc may reload the
    // CHAINID opcode across vm.chainId(), assuming it is transaction-constant.
    function currentChain() external view returns(uint256) {return block.chainid;}
    function expected(bytes memory name,uint256 chain,address target) internal pure returns(bytes32) {return keccak256(abi.encode(DOMAIN_TYPE,keccak256(name),chain,target));}
    function readDomain(address target) internal view returns(bytes32) {
        (bool ok,bytes memory out)=target.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));require(ok,"domain call");return abi.decode(out,(bytes32));
    }
    function checkDomain(address target,bytes memory name,uint256 chain,bytes32 value) internal view {
        bytes32 domain=expected(name,chain,target);require(readDomain(target)==domain,"domain model");
        (bool ok,bytes memory out)=target.staticcall(abi.encodeWithSignature("digest(bytes32)",value));require(ok,"digest call");
        require(abi.decode(out,(bytes32))==keccak256(abi.encodePacked(hex"1901",domain,value)),"typed digest model");
    }
    function testFuzz_domains(bytes memory name,uint64 fork,bytes32 value) public {
        address f=deploy(name);address s=address(new SolidityPermitFoundations(name));uint256 original=this.currentChain();
        checkDomain(f,name,original,value);checkDomain(s,name,original,value);
        vm.chainId(uint256(fork));checkDomain(f,name,uint256(fork),value);checkDomain(s,name,uint256(fork),value);
        vm.chainId(original);checkDomain(f,name,original,value);checkDomain(s,name,original,value);
    }
    function test_delegateCacheAndPayableRevocation() public {
        bytes memory name="Uniswap v4 Positions NFT";DomainRelay relay=new DomainRelay();uint256 original=this.currentChain();
        bytes memory selector=abi.encodeWithSignature("DOMAIN_SEPARATOR()");
        require(abi.decode(relay.invoke(fe,selector),(bytes32))==expected(name,original,fe),"cached Fe domain in delegatecall");
        require(abi.decode(relay.invoke(address(sol),selector),(bytes32))==expected(name,original,address(sol)),"cached Solidity domain in delegatecall");
        vm.chainId(original+1);
        bytes32 rebuilt=expected(name,original+1,address(relay));
        require(abi.decode(relay.invoke(fe,selector),(bytes32))==rebuilt,"Fe delegated rebuild");
        require(abi.decode(relay.invoke(address(sol),selector),(bytes32))==rebuilt,"Solidity delegated rebuild");vm.chainId(original);
        (bool ok,)=compare(abi.encodeWithSignature("revokeNonce(uint256)",type(uint256).max),1);require(ok,"payable revocation");
        require(fe.balance==1&&address(sol).balance==1,"revocation retains value");
        (ok,)=compare(abi.encodeWithSignature("revokeNonce(uint256)",type(uint256).max),1);require(!ok,"payable replay");
        require(fe.balance==1&&address(sol).balance==1,"replay value rollback");bitmap(address(this),type(uint256).max>>8);
    }
}
