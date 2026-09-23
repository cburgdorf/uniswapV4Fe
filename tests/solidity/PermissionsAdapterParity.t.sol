// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {PermissionsAdapter} from "./periphery/src/hooks/permissionedPools/PermissionsAdapter.sol";
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
    address public expectedAccount;
    address public expectedToken;
    function expect(address account,address token_) external { expectedAccount=account;expectedToken=token_; }
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
        if(expectedToken!=address(0)) {
            (address account,address token_)=abi.decode(data[4:],(address,address));
            require(account==expectedAccount&&token_==expectedToken,"checker arguments");
        }
        if(failCheck) revert("check failure");
        return flags;
    }
}
contract RawAdapterToken {
    bytes public response;
    bool public fails;
    function configure(bytes memory data,bool fail) external {response=data;fails=fail;}
    fallback(bytes calldata) external returns(bytes memory) {
        bytes memory out=response;
        if(fails) assembly ("memory-safe") {revert(add(out,32),mload(out))}
        return out;
    }
}
contract PermissionsAdapterParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant OWNER=address(0xA11CE);
    address constant POOL=address(0xB001);
    address constant USER=address(0x123);
    address constant SPENDER=address(0x456);
    AdapterToken token;
    AdapterChecker checker;
    address target;
    bytes creation;
    bytes feRuntime;
    bytes solRuntime;
    function attempt(bytes memory code) internal returns(address a,bytes memory out) {
        assembly ("memory-safe") {
            a:=create(0,add(code,32),mload(code))
            let n:=returndatasize()
            out:=mload(0x40) mstore(out,n) returndatacopy(add(out,32),0,n)
            mstore(0x40,add(add(out,32),and(add(n,31),not(31))))
        }
    }
    function storageHash(address a) internal view returns(bytes32 h) {
        for(uint256 i;i<10;++i) h=keccak256(abi.encode(h,vm.load(a,bytes32(i))));
        for(uint256 i=3;i<=4;++i) {
            uint256 base=uint256(keccak256(abi.encode(i)));
            for(uint256 j;j<12;++j) h=keccak256(abi.encode(h,vm.load(a,bytes32(base+j))));
        }
        address[5] memory accounts=[POOL,OWNER,USER,SPENDER,address(0)];
        for(uint256 i;i<accounts.length;++i) {
            address who=accounts[i];
            for(uint256 slot;slot<10;++slot) {
                if(slot!=0&&slot!=8&&slot!=9) continue;
                h=keccak256(abi.encode(h,vm.load(a,keccak256(abi.encode(who,slot)))));
            }
            h=keccak256(abi.encode(h,token.balanceOf(who)));
            for(uint256 j;j<accounts.length;++j) {
                bytes32 inner=keccak256(abi.encode(who,uint256(1)));
                bytes32 slot=keccak256(abi.encode(accounts[j],inner));
                h=keccak256(abi.encode(h,vm.load(a,slot)));
            }
        }
        h=keccak256(abi.encode(h,token.balanceOf(a),a.balance));
    }
    function configure(address underlying,address pool,address owner,address allowlist) internal returns(bool) {
        bytes memory args=abi.encode(underlying,pool,owner,allowlist);
        uint256 snap=vm.snapshotState(); vm.recordLogs();
        (address a,bytes memory x)=attempt(bytes.concat(creation,args));
        bytes memory runtime=a.code; Vm.Log[] memory logs=vm.getRecordedLogs(); bytes32 hash=storageHash(a);
        require(vm.revertToState(snap)); vm.recordLogs();
        (address b,bytes memory y)=attempt(bytes.concat(type(PermissionsAdapter).creationCode,args));
        require(a==b,"constructor address/status");
        require(keccak256(x)==keccak256(y),"constructor revert");
        require(keccak256(abi.encode(logs))==keccak256(abi.encode(vm.getRecordedLogs())),"constructor events");
        require(hash==storageHash(b),"constructor storage");
        if(a==address(0)) return false;
        target=b; feRuntime=runtime; solRuntime=b.code; return true;
    }
    function setUp() public {
        token=new AdapterToken(); checker=new AdapterChecker();
        token.metadata(abi.encode("Asset name"),abi.encode("AST"),abi.encode(uint256(6)),false);
        creation=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        require(configure(address(token),POOL,OWNER,address(checker)));
        vm.deal(address(this),100);
    }
    function invoke(bytes memory data,address actor,uint256 value) internal returns(bool ok,bytes memory out,bytes32 hash) {
        vm.recordLogs();vm.prank(actor);(ok,out)=target.call{value:value,gas:5_000_000}(data);
        hash=keccak256(abi.encode(storageHash(target),vm.getRecordedLogs()));
    }
    function compare(bytes memory data,address actor,uint256 value) internal returns(bool ok,bytes memory out) {
        uint256 snap=vm.snapshotState();vm.etch(target,feRuntime);
        (bool left,bytes memory x,bytes32 a)=invoke(data,actor,value);
        require(vm.revertToState(snap));vm.etch(target,solRuntime);
        bytes32 b;(ok,out,b)=invoke(data,actor,value);
        require(left==ok,"status");require(keccak256(x)==keccak256(out),"return/revert");require(a==b,"state/events/rollback");
    }
    function success(bytes memory data,address actor) internal {
        (bool ok,)=compare(data,actor,0);require(ok,"expected success");
    }
    function getters() internal {
        string[10] memory names=["POOL_MANAGER()","PERMISSIONED_TOKEN()","name()","symbol()","decimals()","totalSupply()","owner()","pendingOwner()","allowListChecker()","swappingEnabled()"];
        for(uint256 i;i<names.length;++i) success(abi.encodeWithSignature(names[i]),USER);
        success(abi.encodeWithSignature("balanceOf(address)",POOL),USER);
        success(abi.encodeWithSignature("allowedWrappers(address)",USER),USER);
        success(abi.encodeWithSignature("allowedHooks(address)",USER),USER);
        success(abi.encodeWithSignature("allowance(address,address)",POOL,SPENDER),USER);
    }
    function fund(uint256 amount) internal {
        token.mint(USER,amount);
        success(abi.encodeWithSignature("depositForVerification(uint256)",amount),USER);
        success(abi.encodeWithSignature("updateAllowedWrapper(address,bool)",USER,true),OWNER);
        success(abi.encodeWithSignature("wrapToPoolManager(uint256)",amount),USER);
    }
    function testFuzz_lifecycle(uint128 deposit,uint128 take,uint8 mode) public {
        fund(deposit);token.mode(mode%7);
        compare(abi.encodeWithSignature("transfer(address,uint256)",USER,uint256(take)),POOL,0);
        getters();
    }
    function testFuzz_allowance(uint128 deposit,uint256 allowance_,uint128 take,bool infinite) public {
        fund(deposit);
        success(abi.encodeWithSignature("approve(address,uint256)",SPENDER,infinite?type(uint256).max:allowance_),POOL);
        compare(abi.encodeWithSignature("transferFrom(address,address,uint256)",POOL,USER,uint256(take)),SPENDER,0);
        getters();
    }
    function testFuzz_admin(uint8 selector,bool enabled,bool authorized) public {
        address actor=authorized?OWNER:USER;
        uint256 which=selector%5;
        if(which==0) compare(abi.encodeWithSignature("updateAllowedHook(address,bool)",USER,enabled),actor,0);
        if(which==1) compare(abi.encodeWithSignature("updateAllowedWrapper(address,bool)",USER,enabled),actor,0);
        if(which==2) compare(abi.encodeWithSignature("updateSwappingEnabled(bool)",enabled),actor,0);
        if(which==3) compare(abi.encodeWithSignature("transferOwnership(address)",enabled?USER:address(0)),actor,0);
        if(which==4) compare(abi.encodeWithSignature("renounceOwnership()"),actor,0);
        compare(abi.encodeWithSignature("acceptOwnership()"),USER,0);
        getters();
    }
    function testFuzz_permission(bytes2 flags,bytes2 required,bool fail) public {
        checker.expect(USER,address(token));
        checker.configure(abi.encode(flags),1,0,0,fail);
        compare(abi.encodeWithSignature("isAllowed(address,bytes2)",USER,required),SPENDER,0);
    }
    function testFuzz_metadata(bytes memory data,uint256 decimals_,bool fail) public {
        if(data.length>256) return;
        token.metadata(abi.encode(string(data)),abi.encode(string(data)),abi.encode(decimals_),fail);
        require(configure(address(token),POOL,OWNER,address(checker)));getters();
    }
    function testFuzz_rawMetadata(bytes memory data) public {
        if(data.length>320)return;
        token.metadata(data,data,data,false);
        require(configure(address(token),POOL,OWNER,address(checker)));getters();
    }
    function testFuzz_sequences(uint256 seed) public {
        token.mint(USER,1000);
        address[4] memory actors=[OWNER,POOL,USER,SPENDER];
        for(uint256 i;i<20;++i) {
            seed=uint256(keccak256(abi.encode(seed,i)));
            address actor=actors[(seed>>8)%4];
            address who=actors[(seed>>16)%4];
            uint256 amount=(seed>>32)%100;
            bool enabled=(seed&1)!=0;
            uint256 op=seed%10;
            bytes memory data;
            if(op==0)data=abi.encodeWithSignature("depositForVerification(uint256)",amount);
            if(op==1)data=abi.encodeWithSignature("updateAllowedWrapper(address,bool)",who,enabled);
            if(op==2)data=abi.encodeWithSignature("wrapToPoolManager(uint256)",amount);
            if(op==3)data=abi.encodeWithSignature("transfer(address,uint256)",who,amount);
            if(op==4)data=abi.encodeWithSignature("approve(address,uint256)",who,enabled?type(uint256).max:amount);
            if(op==5)data=abi.encodeWithSignature("transferFrom(address,address,uint256)",POOL,who,amount);
            if(op==6)data=abi.encodeWithSignature("transferOwnership(address)",who);
            if(op==7)data=abi.encodeWithSignature("acceptOwnership()");
            if(op==8)data=abi.encodeWithSignature("updateAllowedHook(address,bool)",who,enabled);
            if(op==9)data=abi.encodeWithSignature("updateSwappingEnabled(bool)",enabled);
            compare(data,actor,0);
            uint256 supply=abi.decode(readTarget("totalSupply()"),(uint256));
            (bool ok,bytes memory out)=target.staticcall(abi.encodeWithSignature("balanceOf(address)",POOL));
            require(ok&&abi.decode(out,(uint256))==supply,"sole holder invariant");
            require(token.balanceOf(target)>=supply,"backing invariant");
        }
    }
    function readTarget(string memory signature) internal view returns(bytes memory out) {
        bool ok;(ok,out)=target.staticcall(abi.encodeWithSignature(signature));require(ok);
    }
    function test_metadataAndReturndataBoundaries() public {
        bytes[5] memory names=[bytes(""),bytes("x"),new bytes(31),new bytes(32),new bytes(65)];
        for(uint256 i;i<names.length;++i) {
            // Accept unpadded strings, but reject noncanonical offsets and zero length.
            bytes memory raw=abi.encodePacked(uint256(32),names[i].length,names[i]);
            token.metadata(raw,raw,abi.encodePacked(uint256(255),bytes1(0x01)),false);
            require(configure(address(token),POOL,OWNER,address(checker)));getters();
        }
        RawAdapterToken rawToken=new RawAdapterToken();
        require(configure(address(rawToken),POOL,OWNER,address(checker)));
        success(abi.encodeWithSignature("updateAllowedWrapper(address,bool)",USER,true),OWNER);
        for(uint256 n;n<=33;++n) {
            bytes memory data=new bytes(n);
            rawToken.configure(data,false);
            compare(abi.encodeWithSignature("wrapToPoolManager(uint256)",0),USER,0);
        }
        rawToken.configure(hex"deadbeef",true);
        compare(abi.encodeWithSignature("wrapToPoolManager(uint256)",0),USER,0);
    }
    function test_constructorAndCheckerFailures() public {
        require(!configure(address(token),POOL,address(0),address(checker)));
        require(!configure(address(token),POOL,OWNER,address(0)));
        for(uint8 i;i<4;++i) {
            checker.configure(abi.encode(bytes2(0xffff)),i==0?0:1,0,i,false);
            require(!configure(address(token),POOL,OWNER,address(checker)));
            compare(abi.encodeWithSignature("updateAllowListChecker(address)",address(checker)),OWNER,0);
        }
        checker.configure(abi.encode(bytes2(0xffff)),2,1,0,false);
        require(!configure(address(token),POOL,OWNER,address(checker)));
        checker.configure(abi.encode(bytes2(0xffff)),2,0,0,false);
        require(configure(address(token),POOL,OWNER,address(checker))); // ERC165 accepts any nonzero word.
        success(abi.encodeWithSignature("updateSwappingEnabled(bool)",true),OWNER);
        success(abi.encodeWithSignature("updateAllowListChecker(address)",address(checker)),OWNER);
        getters();
    }
    function test_ownerAndTransferBoundaries() public {
        fund(10);
        success(abi.encodeWithSignature("updateAllowedHook(address,bool)",USER,true),OWNER);
        success(abi.encodeWithSignature("updateAllowedHook(address,bool)",USER,true),OWNER);
        success(abi.encodeWithSignature("transferOwnership(address)",USER),OWNER);
        success(abi.encodeWithSignature("transferOwnership(address)",address(0)),OWNER);
        compare(abi.encodeWithSignature("acceptOwnership()"),USER,0);
        success(abi.encodeWithSignature("transferOwnership(address)",USER),OWNER);
        success(abi.encodeWithSignature("acceptOwnership()"),USER);
        compare(abi.encodeWithSignature("updateSwappingEnabled(bool)",true),OWNER,0);
        for(uint256 i;i<3;++i) {
            address a=i==0?address(0):i==1?POOL:USER;
            compare(abi.encodeWithSignature("transfer(address,uint256)",a,0),POOL,0);
            compare(abi.encodeWithSignature("transfer(address,uint256)",USER,0),a,0);
            compare(abi.encodeWithSignature("approve(address,uint256)",a,0),USER,0);
            compare(abi.encodeWithSignature("transferFrom(address,address,uint256)",a,USER,0),SPENDER,0);
        }
        token.setBalance(target,0);
        compare(abi.encodeWithSignature("wrapToPoolManager(uint256)",0),USER,0); // checked underflow
        require(configure(address(token),address(0),OWNER,address(checker)));
        success(abi.encodeWithSignature("updateAllowedWrapper(address,bool)",USER,true),OWNER);
        compare(abi.encodeWithSignature("wrapToPoolManager(uint256)",0),USER,0);
    }
    function test_malformedAndDepositFailures() public {
        token.mint(USER,10);
        for(uint8 m;m<7;++m) {
            token.mode(m);token.setBalance(USER,10);
            compare(abi.encodeWithSignature("depositForVerification(uint256)",1),USER,0);
        }
        compare(hex"",USER,0);compare(hex"12345678",USER,0);
        compare(abi.encodeWithSignature("owner()"),USER,1);
        compare(abi.encodePacked(bytes4(keccak256("updateSwappingEnabled(bool)")),bytes32(uint256(2))),OWNER,0);
        checker.configure(hex"01",1,0,0,false);
        compare(abi.encodeWithSignature("isAllowed(address,bytes2)",USER,bytes2(0)),USER,0);
        checker.configure(abi.encode(uint256(1)),1,0,0,false);
        compare(abi.encodeWithSignature("isAllowed(address,bytes2)",USER,bytes2(0)),USER,0);
        // Reentrant token callback can mutate adapter admin state before transfer returns.
        token.mode(0);token.callback(target,abi.encodeWithSignature("updateSwappingEnabled(bool)",true));
        success(abi.encodeWithSignature("transferOwnership(address)",address(token)),OWNER);
        success(abi.encodeWithSignature("acceptOwnership()"),address(token));
        success(abi.encodeWithSignature("depositForVerification(uint256)",1),USER);
    }
}
