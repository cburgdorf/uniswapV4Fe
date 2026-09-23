// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC721Permit_v4} from "./periphery/src/base/ERC721Permit_v4.sol";
import {ERC721PermitHash} from "./periphery/src/libraries/ERC721PermitHash.sol";
interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function sign(uint256,bytes32) external pure returns(uint8,bytes32,bytes32);
    function addr(uint256) external pure returns(address);
    function prank(address) external;
    function deal(address,uint256) external;
    function warp(uint256) external;
    function load(address,bytes32) external view returns(bytes32);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract SolidityERC721Permit is ERC721Permit_v4 {
    constructor(string memory n,string memory s) ERC721Permit_v4(n,s) {}
    function tokenURI(uint256) public pure override returns(string memory) {return "";}
    function mint(address to,uint256 id) external {_mint(to,id);}
    function burn(uint256 id) external {_burn(id);}
    function allowed(address spender,uint256 id) external view returns(bool) {return _isApprovedOrOwner(spender,id);}
}
contract NFTReceiver {
    uint256 public mode;
    bytes public received;
    function configure(uint256 m) external {mode=m;}
    fallback() external {
        received=msg.data;
        uint256 m=mode;
        if(m==2)revert("receiver rejection");
        if(m>=6){
            (, ,uint256 id,)=abi.decode(msg.data[4:],(address,address,uint256,bytes));
            (bool ok,)=msg.sender.call(abi.encodeWithSignature("transferFrom(address,address,uint256)",address(this),address(0xb0b),id));require(ok,"reentry transfer");
            if(m==7)revert("rollback reentry");
        }
        assembly {
            mstore(0,shl(224,0x150b7a02))
            switch m
            case 1 {mstore(0,0)}
            case 3 {return(0,4)}
            case 4 {mstore(0,or(mload(0),1))}
            case 5 {return(0,10000)}
            return(0,32)
        }
    }
}
contract PermitSigner {
    uint256 mode;
    constructor(uint256 m){mode=m;}
    function isValidSignature(bytes32,bytes calldata) external view returns(bytes4) {
        if(mode==2)revert("permit signer rejection");
        return mode==0?bytes4(0x1626ba7e):bytes4(0);
    }
}
contract ERC721PermitParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;SolidityERC721Permit sol;
    address constant ALICE=address(0xa11ce);address constant BOB=address(0xb0b);address constant OP=address(0xc0ffee);
    function deploy(bytes memory name,bytes memory symbol) internal {
        bytes memory code=abi.encodePacked(vm.parseBytes(vm.readFile("fe-bytecode.txt")),abi.encode(name,symbol));
        address f;assembly {f:=create(0,add(code,32),mload(code))}require(f.code.length>0,"Fe deploy");fe=f;
        sol=new SolidityERC721Permit(string(name),string(symbol));
    }
    function setUp() public {deploy(bytes("Uniswap v4 Positions NFT"),bytes("UNI-V4-POSM"));vm.deal(address(this),100 ether);}
    function compare(bytes memory data,address caller,uint256 value) internal returns(bool ok,bytes memory out) {
        vm.deal(caller,2 ether);
        vm.recordLogs();vm.prank(caller);(ok,out)=fe.call{value:value}(data);Vm.Log[] memory a=vm.getRecordedLogs();
        vm.recordLogs();vm.prank(caller);(bool refOk,bytes memory expected)=address(sol).call{value:value}(data);Vm.Log[] memory b=vm.getRecordedLogs();
        require(ok==refOk,"ERC721 status mismatch");require(keccak256(out)==keccak256(expected),"ERC721 result mismatch");
        require(a.length==b.length,"log count");
        for(uint256 i;i<a.length;i++){require(a[i].emitter==fe&&b[i].emitter==address(sol),"emitter");require(keccak256(abi.encode(a[i].topics,a[i].data))==keccak256(abi.encode(b[i].topics,b[i].data)),"logs");}
        require(fe.balance==address(sol).balance,"ETH rollback");
    }
    function slot(bytes32 key) internal view {require(vm.load(fe,key)==vm.load(address(sol),key),"storage");}
    function state(uint256 id,address a,address b) internal view {
        slot(keccak256(abi.encode(id,uint256(2))));slot(keccak256(abi.encode(id,uint256(4))));
        slot(keccak256(abi.encode(a,uint256(3))));slot(keccak256(abi.encode(b,uint256(3))));
        slot(keccak256(abi.encode(OP,keccak256(abi.encode(a,uint256(5))))));
    }
    function testFuzz_lifecycle(uint256 id,uint8 action,bool approved) public {
        compare(abi.encodeCall(sol.mint,(ALICE,id)),ALICE,0);state(id,ALICE,BOB);
        compare(abi.encodeCall(sol.setApprovalForAll,(OP,approved)),ALICE,0);
        compare(abi.encodeCall(sol.approve,(BOB,id)),action%2==0?ALICE:OP,0);
        address caller=action%4==0?ALICE:action%4==1?BOB:action%4==2?OP:address(999);
        compare(abi.encodeCall(sol.transferFrom,(ALICE,action%3==0?ALICE:BOB,id)),caller,0);state(id,ALICE,BOB);
        compare(abi.encodeCall(sol.burn,(id)),ALICE,0);state(id,ALICE,BOB);
        compare(abi.encodeCall(sol.ownerOf,(id)),ALICE,0);
        compare(abi.encodeCall(sol.burn,(id)),ALICE,0);
    }
    function testFuzz_failures(uint256 id,uint8 action) public {
        compare(abi.encodeCall(sol.ownerOf,(id)),ALICE,0);
        compare(abi.encodeCall(sol.balanceOf,(address(0))),ALICE,0);
        compare(abi.encodeCall(sol.approve,(BOB,id)),ALICE,0);
        compare(abi.encodeCall(sol.mint,(address(0),id)),ALICE,0);
        compare(abi.encodeCall(sol.mint,(ALICE,id)),ALICE,0);
        compare(abi.encodeCall(sol.mint,(BOB,id)),ALICE,0);
        compare(abi.encodeCall(sol.transferFrom,(action%2==0?BOB:ALICE,address(0),id)),BOB,0);
        compare(abi.encodeCall(sol.allowed,(BOB,id)),ALICE,0);state(id,ALICE,BOB);
    }
    function signature(address target,uint256 key,bytes32 hash) internal view returns(bytes memory) {
        (bool ok,bytes memory out)=target.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));require(ok);
        bytes32 digest=keccak256(abi.encodePacked(hex"1901",abi.decode(out,(bytes32)),hash));
        (uint8 v,bytes32 r,bytes32 s)=vm.sign(key,digest);return abi.encodePacked(r,s,v);
    }
    function permitCall(bytes memory a,bytes memory b,address owner,uint256 nonce,bool expected) internal {
        vm.recordLogs();(bool ok,bytes memory out)=fe.call{value:1}(a);Vm.Log[] memory la=vm.getRecordedLogs();
        vm.recordLogs();(bool refOk,bytes memory refOut)=address(sol).call{value:1}(b);Vm.Log[] memory lb=vm.getRecordedLogs();
        require(ok==refOk&&ok==expected,"permit status");require(keccak256(out)==keccak256(refOut),"permit error");
        require(la.length==lb.length,"permit log count");
        for(uint256 i;i<la.length;i++)require(keccak256(abi.encode(la[i].topics,la[i].data))==keccak256(abi.encode(lb[i].topics,lb[i].data)),"permit log");
        slot(keccak256(abi.encode(nonce>>8,keccak256(abi.encode(owner,uint256(6))))));
        require(fe.balance==address(sol).balance,"permit ETH");
    }
    function testFuzz_permit(uint256 id,uint256 nonce,bool all,bool expired) public {
        uint256 key=123;address owner=vm.addr(key);compare(abi.encodeCall(sol.mint,(owner,id)),ALICE,0);
        vm.warp(100);uint256 deadline=expired?99:100;
        bytes32 hash=all?ERC721PermitHash.hashPermitForAll(OP,true,nonce,deadline):ERC721PermitHash.hashPermit(OP,id,nonce,deadline);
        bytes memory fs=signature(fe,key,hash);bytes memory ss=signature(address(sol),key,hash);
        bytes memory a=all?abi.encodeCall(sol.permitForAll,(owner,OP,true,deadline,nonce,fs)):abi.encodeCall(sol.permit,(OP,id,deadline,nonce,fs));
        bytes memory b=all?abi.encodeCall(sol.permitForAll,(owner,OP,true,deadline,nonce,ss)):abi.encodeCall(sol.permit,(OP,id,deadline,nonce,ss));
        if(nonce%2==0){uint256 size=all?293:261;assembly {mstore(a,size) mstore(b,size)}}
        permitCall(a,b,owner,nonce,!expired);state(id,owner,OP);
        permitCall(a,b,owner,nonce,false);state(id,owner,OP);
        compare(abi.encodeCall(sol.transferFrom,(owner,BOB,id)),OP,0);state(id,owner,BOB);
    }
    function testFuzz_safeTransfer(uint256 id,bytes memory data,uint8 mode) public {
        NFTReceiver receiver=new NFTReceiver();receiver.configure(mode%8);
        compare(abi.encodeCall(sol.mint,(ALICE,id)),ALICE,0);
        compare(abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)",ALICE,address(receiver),id,data),ALICE,0);
        state(id,ALICE,address(receiver));state(id,BOB,address(receiver));
        if(mode%8==0||mode%8==5||mode%8==6)require(keccak256(receiver.received())==keccak256(abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)",ALICE,ALICE,id,data)),"callback args");
    }
    function testFuzz_metadata(bytes memory name,bytes memory symbol) public {
        if(name.length>200||symbol.length>200)return;
        deploy(name,symbol);
        compare(abi.encodeWithSignature("name()"),ALICE,0);compare(abi.encodeWithSignature("symbol()"),ALICE,0);
        slot(bytes32(0));slot(bytes32(uint256(1)));
        for(uint256 i;i<(name.length+31)/32;i++)slot(bytes32(uint256(keccak256(abi.encode(uint256(0))))+i));
        for(uint256 i;i<(symbol.length+31)/32;i++)slot(bytes32(uint256(keccak256(abi.encode(uint256(1))))+i));
    }
    function test_revokedAndWrongSignatures() public {
        address owner=vm.addr(123);uint256 id=42;uint256 nonce=1234;uint256 deadline=100;
        compare(abi.encodeCall(sol.mint,(owner,id)),ALICE,0);vm.warp(100);
        compare(abi.encodeCall(sol.revokeNonce,(nonce)),owner,1);
        bytes32 hash=ERC721PermitHash.hashPermit(OP,id,nonce,deadline);
        bytes memory fs=signature(fe,123,hash);bytes memory ss=signature(address(sol),123,hash);
        permitCall(abi.encodeCall(sol.permit,(OP,id,deadline,nonce,fs)),abi.encodeCall(sol.permit,(OP,id,deadline,nonce,ss)),owner,nonce,false);
        // Wrong owner must fail signature verification even with an unused nonce.
        nonce++;
        hash=ERC721PermitHash.hashPermit(OP,id,nonce,deadline);
        fs=signature(fe,999,hash);ss=signature(address(sol),999,hash);
        permitCall(abi.encodeCall(sol.permit,(OP,id,deadline,nonce,fs)),abi.encodeCall(sol.permit,(OP,id,deadline,nonce,ss)),owner,nonce,false);
        compare(abi.encodeCall(sol.permit,(OP,id,99,nonce,bytes("bad"))),ALICE,1);
        compare(abi.encodeCall(sol.permit,(OP,99,deadline,nonce,bytes("bad"))),ALICE,1);
        state(id,owner,OP);
    }

    function testFuzz_contractPermit(bytes memory sig,uint256 nonce,bool all,uint8 mode) public {
        PermitSigner owner=new PermitSigner(mode%3);uint256 id=123;
        compare(abi.encodeCall(sol.mint,(address(owner),id)),ALICE,0);vm.warp(100);
        bytes memory data=all?abi.encodeCall(sol.permitForAll,(address(owner),OP,true,100,nonce,sig)):abi.encodeCall(sol.permit,(OP,id,100,nonce,sig));
        permitCall(data,data,address(owner),nonce,mode%3==0);state(id,address(owner),OP);
    }

}
