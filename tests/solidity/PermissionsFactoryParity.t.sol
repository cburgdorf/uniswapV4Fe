// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/PermissionsAdapterFactory.sol";
interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
    function etch(address, bytes calldata) external;
    function store(address, bytes32, bytes32) external;
    function load(address, bytes32) external view returns (bytes32);
    function deal(address, uint256) external;
    function prank(address) external;
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}
contract AdapterToken {
    mapping(address => uint256) public balanceOf;
    bytes public nameData;
    bytes public symbolData;
    bytes public decimalData;
    bool public failMetadata;
    uint8 public transferMode;
    address public callbackTarget;
    bytes public callbackData;
    event Transfer(address indexed from, address indexed to, uint256 value);
    function metadata(bytes memory n, bytes memory s, bytes memory d, bool fail) external {
        nameData=n; symbolData=s; decimalData=d; failMetadata=fail;
    }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function setBalance(address to, uint256 amount) external { balanceOf[to]=amount; }
    function mode(uint8 m) external { transferMode=m; }
    function callback(address target, bytes memory data) external { callbackTarget=target; callbackData=data; }
    function transfer(address to, uint256 amount) external returns (bool) { move(msg.sender,to,amount); return true; }
    function transferFrom(address from,address to,uint256 amount) external returns (bool) { move(from,to,amount); return true; }
    function move(address from,address to,uint256 amount) internal {
        require(balanceOf[from]>=amount,"token balance");
        balanceOf[from]-=amount; balanceOf[to]+=amount; emit Transfer(from,to,amount);
        if(callbackTarget!=address(0)) {
            (bool ok, bytes memory out)=callbackTarget.call(callbackData);
            if(!ok) assembly ("memory-safe") { revert(add(out,32),mload(out)) }
        }
        uint8 m=transferMode;
        if(m==1) assembly ("memory-safe") { return(0,0) }
        if(m==2) assembly ("memory-safe") { mstore(0,0) return(0,32) }
        if(m==3) assembly ("memory-safe") { mstore(0,2) return(0,32) }
        if(m==4) assembly ("memory-safe") { mstore(0,1) return(0,31) }
        if(m==5) assembly ("memory-safe") { mstore(0,0xabcdef) revert(0,32) }
        if(m==6) assembly ("memory-safe") { mstore(0,1) mstore(32,123) return(0,64) }
    }
    fallback(bytes calldata data) external returns(bytes memory) {
        if(failMetadata) revert("metadata failure");
        if(bytes4(data)==bytes4(keccak256("name()"))) return nameData;
        if(bytes4(data)==bytes4(keccak256("symbol()"))) return symbolData;
        if(bytes4(data)==bytes4(keccak256("decimals()"))) return decimalData;
        revert("unknown");
    }
}
contract AdapterChecker {
    bytes public flags=abi.encode(bytes2(0xffff));
    uint256 public support=1;
    uint256 public invalidSupport;
    uint8 public supportMode;
    bool public failCheck;
    function configure(bytes memory f,uint256 yes,uint256 invalid_,uint8 mode_,bool fail) external {
        flags=f; support=yes; invalidSupport=invalid_; supportMode=mode_; failCheck=fail;
    }
    fallback(bytes calldata data) external returns(bytes memory) {
        if(bytes4(data)==bytes4(keccak256("supportsInterface(bytes4)"))) {
            uint8 m=supportMode;
            if(m==1) revert("support failure");
            if(m==2) return hex"01";
            if(m==3) assembly { invalid() }
            bytes4 id=abi.decode(data[4:],(bytes4));
            return abi.encode(id==0xffffffff ? invalidSupport : support);
        }
        require(bytes4(data)==bytes4(keccak256("checkAllowlist(address,address)")),"selector");
        if(failCheck) revert("check failure");
        return flags;
    }
}
contract PermissionsFactoryParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant OWNER=address(0xA11CE);
    address constant POOL=address(0xB001);
    address constant USER=address(0x123);
    AdapterToken token;
    AdapterChecker checker;
    address target;
    bytes creation;
    bytes feRuntime;
    bytes solRuntime;
    bool exercise;
    function deploy(bytes memory code) internal returns(address a) {
        assembly ("memory-safe") { a:=create(0,add(code,32),mload(code)) }
        require(a!=address(0),"factory creation");
    }
    function setUp() public {
        token=new AdapterToken();checker=new AdapterChecker();
        token.metadata(abi.encode("Factory Asset"),abi.encode("FCT"),abi.encode(uint256(8)),false);
        creation=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        configure(POOL);
        vm.deal(address(this),100);
    }
    function configure(address pool) internal {
        uint256 snap=vm.snapshotState();
        address a=deploy(bytes.concat(creation,abi.encode(pool))); bytes memory runtime=a.code;
        require(vm.revertToState(snap));
        address b=deploy(bytes.concat(type(PermissionsAdapterFactory).creationCode,abi.encode(pool)));
        require(a==b,"factory address");target=b;feRuntime=runtime;solRuntime=b.code;
    }
    function read(address who,bytes memory data) internal view returns(bytes memory out) {
        bool ok;(ok,out)=who.staticcall(data);require(ok,"getter");
    }
    function callChild(address child,bytes memory data,address actor) internal {
        vm.prank(actor);(bool ok,bytes memory out)=child.call(data);
        if(!ok) assembly ("memory-safe") { revert(add(out,32),mload(out)) }
    }
    function invoke(bytes memory data,address actor,uint256 value) internal returns(bool ok,bytes memory out,bytes32 hash) {
        vm.recordLogs();vm.prank(actor);(ok,out)=target.call{value:value,gas:15_000_000}(data);
        address child;
        if(ok && bytes4(data)==bytes4(keccak256("createPermissionsAdapter(address,address,address)"))) {
            child=abi.decode(out,(address));require(child.code.length>0,"child code missing");
            string[10] memory names=["POOL_MANAGER()","PERMISSIONED_TOKEN()","name()","symbol()","decimals()","totalSupply()","owner()","pendingOwner()","allowListChecker()","swappingEnabled()"];
            for(uint256 i;i<names.length;++i) hash=keccak256(abi.encode(hash,read(child,abi.encodeWithSignature(names[i]))));
            if(exercise) {
                token.mint(USER,5);
                callChild(child,abi.encodeWithSignature("depositForVerification(uint256)",5),USER);
                callChild(child,abi.encodeWithSignature("updateAllowedWrapper(address,bool)",USER,true),OWNER);
                callChild(child,abi.encodeWithSignature("wrapToPoolManager(uint256)",5),USER);
                callChild(child,abi.encodeWithSignature("transfer(address,uint256)",USER,3),POOL);
                hash=keccak256(abi.encode(hash,read(child,abi.encodeWithSignature("totalSupply()")),token.balanceOf(child),token.balanceOf(USER)));
            }
            for(uint256 i;i<10;++i)hash=keccak256(abi.encode(hash,vm.load(child,bytes32(i))));
        } else if(data.length>=36) assembly ("memory-safe") { child:=mload(add(data,36)) }
        hash=keccak256(abi.encode(hash,vm.getRecordedLogs(),read(target,abi.encodeWithSignature("POOL_MANAGER()")),
            read(target,abi.encodeWithSignature("permissionsAdapterOf(address)",child)),
            read(target,abi.encodeWithSignature("verifiedPermissionsAdapterOf(address)",child)),target.balance));
    }
    function compare(bytes memory data,address actor,uint256 value) internal returns(bool ok,bytes memory out) {
        uint256 snap=vm.snapshotState();vm.etch(target,feRuntime);
        (bool a,bytes memory x,bytes32 left)=invoke(data,actor,value);
        require(vm.revertToState(snap));vm.etch(target,solRuntime);
        bytes32 right;(ok,out,right)=invoke(data,actor,value);
        require(a==ok,"status");require(keccak256(x)==keccak256(out),"return/revert");require(left==right,"state/events/child");
    }
    function create(address underlying,address owner,address check) internal returns(bool ok,address child) {
        bytes memory out;(ok,out)=compare(abi.encodeWithSignature("createPermissionsAdapter(address,address,address)",underlying,owner,check),USER,0);
        if(ok)child=abi.decode(out,(address));
    }
    function testFuzz_createAndVerify(uint128 amount,bool useExercise,bool repeat) public {
        exercise=useExercise;
        (bool ok,address child)=create(address(token),OWNER,address(checker));require(ok);
        compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);
        token.mint(child,amount);
        compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);
        if(repeat)compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),OWNER,0);
        (ok,)=create(address(token),OWNER,address(checker));require(ok);
    }
    function testFuzz_constructorFailure(address owner,uint8 mode) public {
        checker.configure(abi.encode(bytes2(0xffff)),1,0,mode%4,false);
        create(address(token),owner,address(checker));
    }
    function testFuzz_pool(address pool) public {
        configure(pool);
        (bool ok,)=create(address(token),OWNER,address(checker));require(ok);
    }
    function testFuzz_unknown(address child) public {
        compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);
        compare(abi.encodeWithSignature("permissionsAdapterOf(address)",child),USER,0);
        compare(abi.encodeWithSignature("verifiedPermissionsAdapterOf(address)",child),USER,0);
    }
    function test_boundaries() public {
        (bool ok,)=create(address(token),address(0),address(checker));require(!ok);
        (ok,)=create(address(token),OWNER,address(0));require(!ok);
        address child;(ok,child)=create(address(0),OWNER,address(checker));require(ok);
        (ok,)=compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);require(!ok);
        (ok,child)=create(address(0x999),OWNER,address(checker));require(ok);
        (ok,)=compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);require(!ok);
        (ok,child)=create(address(token),OWNER,address(checker));require(ok);
        (ok,)=compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);require(!ok);
        token.mint(child,1);
        (ok,)=compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);require(ok);
        (ok,)=compare(abi.encodeWithSignature("verifyPermissionsAdapter(address)",child),USER,0);require(!ok);
        compare(hex"",USER,0);compare(hex"12345678",USER,0);
        compare(abi.encodeWithSignature("POOL_MANAGER()"),USER,1);
    }
}
