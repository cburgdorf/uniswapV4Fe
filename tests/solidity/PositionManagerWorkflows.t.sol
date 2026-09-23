// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PositionManager} from "./periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "./periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "./periphery/src/interfaces/external/IWETH9.sol";
import {ISubscriber} from "./periphery/src/interfaces/ISubscriber.sol";
import {IAllowanceTransfer} from "./permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {PoolId,PoolIdLibrary} from "./reference/src/types/PoolId.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {TickMath} from "./reference/src/libraries/TickMath.sol";
import {StateLibrary} from "./reference/src/libraries/StateLibrary.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function prank(address) external;
    function load(address,bytes32) external view returns(bytes32);
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
    function exists(string calldata) external view returns(bool);
    function skip(bool) external;
    function etch(address,bytes calldata) external;
}
contract PositionToken {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function approve(address spender,uint256 amount) external returns(bool){allowance[msg.sender][spender]=amount;return true;}
    function transfer(address to,uint256 amount) external returns(bool){move(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool){
        if(allowance[from][msg.sender]!=type(uint256).max)allowance[from][msg.sender]-=amount;move(from,to,amount);return true;
    }
    function move(address from,address to,uint256 amount) internal {balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);}
}
contract PositionWeth is PositionToken {
    function deposit() external payable {balanceOf[msg.sender]+=msg.value;}
    function withdraw(uint256 amount) external {balanceOf[msg.sender]-=amount;(bool ok,)=msg.sender.call{value:amount}("");require(ok);}
}
contract PositionDescriptorProbe {
    function tokenURI(address,uint256 id) external pure returns(string memory){return string(abi.encodePacked("position:",id));}
}
contract PositionSubscriberProbe {
    uint256 public modifications;uint256 public burns;
    function notifySubscribe(uint256 id,bytes calldata) external {require(address(PositionManager(payable(msg.sender)).subscriber(id))==address(this));}
    function notifyUnsubscribe(uint256) external {}
    function notifyModifyLiquidity(uint256 id,int256,int256) external {
        modifications++;
        (bool ok,bytes memory err)=msg.sender.call(abi.encodeWithSignature("transferFrom(address,address,uint256)",address(this),address(this),id));
        require(!ok&&bytes4(err)==bytes4(keccak256("PoolManagerMustBeLocked()")),"pool lock before token authorization");
        (ok,err)=msg.sender.call(abi.encodeWithSignature("modifyLiquidities(bytes,uint256)",abi.encode(bytes(""),new bytes[](0)),type(uint256).max));
        require(!ok&&bytes4(err)==bytes4(keccak256("ContractLocked()")),"position lock in callback");
    }
    function notifyBurn(uint256 id,address,uint256,uint256,int256) external {burns++;require(address(PositionManager(payable(msg.sender)).subscriber(id))==address(0));}
}
contract PositionDonor {
    IPoolManager manager;
    receive() external payable {}
    function donate(IPoolManager m,PoolKey memory key,uint256 amount) external {manager=m;m.unlock(abi.encode(key,amount));}
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        require(msg.sender==address(manager));(PoolKey memory key,uint256 amount)=abi.decode(data,(PoolKey,uint256));manager.donate(key,amount,amount,"");
        pay(key.currency0,amount);pay(key.currency1,amount);return "";
    }
    function pay(Currency token,uint256 amount) internal {manager.sync(token);if(Currency.unwrap(token)==address(0))manager.settle{value:amount}();else{PositionToken(Currency.unwrap(token)).transfer(address(manager),amount);manager.settle();}}
}
contract PositionManagerWorkflowsTest {
    using PoolIdLibrary for PoolKey;
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes poolCode;bytes positionCode;bytes permitCode;
    IPoolManager callbackManager;PositionManager callbackPosition;
    PositionToken low;PositionToken high;PositionWeth weth;PositionDescriptorProbe descriptor;PositionSubscriberProbe subscriber;PositionDonor donor;
    receive() external payable {}
    function setUp() public {
        poolCode=vm.parseBytes(vm.readFile("manager-bytecode.txt"));positionCode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));permitCode=vm.parseBytes(vm.readFile("permit2-bytecode.txt"));
        PositionToken a=new PositionToken();PositionToken b=new PositionToken();(low,high)=address(a)<address(b)?(a,b):(b,a);
        weth=new PositionWeth();descriptor=new PositionDescriptorProbe();subscriber=new PositionSubscriberProbe();donor=new PositionDonor();
        low.mint(address(this),1e30);high.mint(address(this),1e30);low.mint(address(donor),1e30);high.mint(address(donor),1e30);
        vm.deal(address(this),1e30);vm.deal(address(donor),1e30);
    }
    function deploy(bytes memory code) internal returns(address a){assembly ("memory-safe") {a:=create(0,add(code,32),mload(code))}require(a.code.length>0,"Fe/reference deploy");}
    function system(bool fePool,bool fePosition) internal returns(IPoolManager manager,PositionManager posm){
        manager=fePool?IPoolManager(deploy(bytes.concat(poolCode,abi.encode(address(this))))):IPoolManager(address(new PoolManager(address(this))));
        IAllowanceTransfer permit=IAllowanceTransfer(deploy(permitCode));
        posm=fePosition?PositionManager(payable(deploy(bytes.concat(positionCode,abi.encode(manager,permit,500000,descriptor,weth))))):new PositionManager(manager,permit,500000,IPositionDescriptor(address(descriptor)),IWETH9(address(weth)));
        low.approve(address(permit),type(uint256).max);high.approve(address(permit),type(uint256).max);
        permit.approve(address(low),address(posm),type(uint160).max,type(uint48).max);permit.approve(address(high),address(posm),type(uint160).max,type(uint48).max);
    }
    function state(IPoolManager manager,PositionManager posm,PoolKey memory key) internal view returns(bytes32){
        bytes32 root=keccak256(abi.encode(key.toId(),uint256(6)));
        bytes32 nft=vm.load(address(posm),keccak256(abi.encode(uint256(1),uint256(2))));
        bytes32 info=vm.load(address(posm),keccak256(abi.encode(uint256(1),uint256(9))));
        bytes32 poolSlot=keccak256(abi.encode(bytes25(PoolId.unwrap(key.toId())),uint256(10)));
        bytes32[] memory packed=new bytes32[](3);for(uint256 i;i<3;i++)packed[i]=vm.load(address(posm),bytes32(uint256(poolSlot)+i));
        return keccak256(abi.encode(manager.extsload(root,7),nft,info,packed,posm.nextTokenId(),posm.getPositionLiquidity(1),posm.msgSender(),address(posm.subscriber(1)),
            low.balanceOf(address(this)),high.balanceOf(address(this)),low.balanceOf(address(manager)),high.balanceOf(address(manager)),
            address(this).balance,address(manager).balance,address(posm).balance,subscriber.modifications(),subscriber.burns()));
    }
    function change(PositionManager posm,PoolKey memory key,bytes memory first,bool minting,bool increasing,bool native,uint256 amount,bool reject) internal returns(bool ok,bytes memory out){
        bytes[] memory params=new bytes[](3);params[0]=first;
        if(increasing){params[1]=abi.encode(key.currency0,key.currency1);params[2]=abi.encode(Currency.wrap(address(0)),address(1));}
        else {params[1]=abi.encode(key.currency0,key.currency1,address(1));params[2]=abi.encode(Currency.wrap(address(0)),address(1));}
        bytes memory actions=abi.encodePacked(minting?bytes1(0x02):increasing?bytes1(0x00):amount==0?bytes1(0x03):bytes1(0x01),increasing?bytes1(0x0d):bytes1(0x11),bytes1(0x14));
        (ok,out)=address(posm).call{value:native&&increasing?1e22:0}(abi.encodeCall(posm.modifyLiquidities,(abi.encode(actions,params),type(uint256).max)));
        require(ok!=reject,"unexpected liquidity status");
    }
    struct Case {uint128 liquidity;bool native;bool reject;bool subscribed;uint64 donated;}
    function run(bool fePool,bool fePosition,Case memory c) internal returns(bytes32){
        (IPoolManager manager,PositionManager posm)=system(fePool,fePosition);
        PoolKey memory key=PoolKey(Currency.wrap(c.native?address(0):address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
        manager.initialize(key,79228162514264337593543950336);
        uint256 liq=uint256(c.liquidity)%1e18+100;
        vm.recordLogs();
        bytes memory mintParams=abi.encode(key,int24(-600),int24(600),liq,c.reject?uint128(0):type(uint128).max,type(uint128).max,address(1),bytes("mint data"));
        (bool ok,bytes memory result)=change(posm,key,mintParams,true,true,c.native,liq,c.reject);
        bytes32 digest=keccak256(abi.encode(ok,result,state(manager,posm,key)));
        if(ok){
            require(posm.ownerOf(1)==address(this)&&posm.nextTokenId()==2&&posm.getPositionLiquidity(1)==liq,"mint state");
            require(keccak256(bytes(posm.name()))==keccak256("Uniswap v4 Positions NFT")&&keccak256(bytes(posm.symbol()))==keccak256("UNI-V4-POSM"));
            require(keccak256(bytes(posm.tokenURI(1)))==keccak256(abi.encodePacked("position:",uint256(1))),"descriptor forwarding");
            (PoolKey memory stored,)=posm.getPoolAndPositionInfo(1);require(keccak256(abi.encode(stored))==keccak256(abi.encode(key)),"stored key");
            if(c.subscribed)posm.subscribe(1,address(subscriber),"subscribed");
            uint256 inc=liq/2+1;change(posm,key,abi.encode(uint256(1),inc,type(uint128).max,type(uint128).max,bytes("increase")),false,true,c.native,inc,false);
            uint256 donated=uint256(c.donated)%1e12;if(donated>0)donor.donate(manager,key,donated);
            digest=keccak256(abi.encode(digest,state(manager,posm,key)));
            uint256 dec=liq/3;change(posm,key,abi.encode(uint256(1),dec,uint128(0),uint128(0),bytes("decrease")),false,false,c.native,dec,false);
            require(posm.getPositionLiquidity(1)==liq+inc-dec,"decrease state");digest=keccak256(abi.encode(digest,state(manager,posm,key)));
            change(posm,key,abi.encode(uint256(1),uint128(0),uint128(0),bytes("burn")),false,false,c.native,0,false);
            require(address(posm.subscriber(1))==address(0)&&uint256(vm.load(address(posm),keccak256(abi.encode(uint256(1),uint256(2)))))==0,"burn state");
            if(c.subscribed)require(subscriber.modifications()==2&&subscriber.burns()==1,"position notifications");
        }else require(posm.nextTokenId()==1,"mint rollback");
        require(posm.msgSender()==address(0),"locker clear");
        Vm.Log[] memory logs=vm.getRecordedLogs();return keccak256(abi.encode(digest,state(manager,posm,key),logs));
    }
    function assertRealMetadata(PositionManager posm,address referenceDescriptor,bool valid) internal view {
        (bool a,bytes memory actual)=address(posm).staticcall(abi.encodeCall(posm.tokenURI,(uint256(1))));
        (bool b,bytes memory expected)=referenceDescriptor.staticcall(abi.encodeWithSignature("tokenURI(address,uint256)",address(posm),uint256(1)));
        require(a==valid&&b==valid&&keccak256(actual)==keccak256(expected),"real descriptor metadata");
    }
    function testFuzz_realDescriptorLifecycle(uint128 rawLiquidity,bool native,int16 startTick) public {
        if(!vm.exists("descriptor-bytecode.txt")){vm.skip(true);return;}
        bytes memory feDescriptor=vm.parseBytes(vm.readFile("descriptor-bytecode.txt"));
        bytes memory solDescriptor=vm.parseBytes(vm.readFile("descriptor-reference-bytecode.txt"));
        uint256 snapshot=vm.snapshotState();
        for(uint256 mode;mode<3;mode++){
            if(mode>0)require(vm.revertToState(snapshot));
            (IPoolManager manager,PositionManager posm)=system(mode==2,mode!=0);
            bytes memory config=abi.encode(manager,address(weth),bytes32("ETH"));
            address real=deploy(bytes.concat(feDescriptor,config));
            address referenceDescriptor=deploy(bytes.concat(solDescriptor,config));
            // The fixture's descriptor address is already embedded in posm.
            // Install the exact deployed Fe runtime, including its immutables.
            vm.etch(address(descriptor),real.code);
            assertRealMetadata(posm,referenceDescriptor,false);
            PoolKey memory key=PoolKey(Currency.wrap(native?address(0):address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
            manager.initialize(key,TickMath.getSqrtPriceAtTick(int24(startTick)%1201));
            uint256 liq=uint256(rawLiquidity)%1e18+100;
            change(posm,key,abi.encode(key,int24(-600),int24(600),liq,type(uint128).max,type(uint128).max,address(1),bytes("mint")),true,true,native,liq,false);
            assertRealMetadata(posm,referenceDescriptor,true);
            uint256 increase=liq/2+1;
            change(posm,key,abi.encode(uint256(1),increase,type(uint128).max,type(uint128).max,bytes("increase")),false,true,native,increase,false);
            assertRealMetadata(posm,referenceDescriptor,true);
            change(posm,key,abi.encode(uint256(1),liq/3,uint128(0),uint128(0),bytes("decrease")),false,false,native,liq/3,false);
            assertRealMetadata(posm,referenceDescriptor,true);
            change(posm,key,abi.encode(uint256(1),uint128(0),uint128(0),bytes("burn")),false,false,native,0,false);
            assertRealMetadata(posm,referenceDescriptor,false);
        }
    }
    function isValidSignature(bytes32,bytes calldata) external pure returns(bytes4) {return 0x1626ba7e;}
    function callDigest(address target,bytes memory data,uint256 value,bool success) internal returns(bytes32) {
        (bool ok,bytes memory result)=target.call{value:value}(data);
        require(ok==success,"guard call status");
        return keccak256(abi.encode(ok,result));
    }
    function guards(bool fePool,bool fePosition) internal returns(bytes32 digest) {
        (IPoolManager manager,PositionManager posm)=system(fePool,fePosition);
        address target=address(posm);
        bytes[] memory empty=new bytes[](0);
        digest=callDigest(target,abi.encodeCall(posm.unlockCallback,(abi.encode(bytes(""),empty))),0,false);
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeCall(posm.modifyLiquidities,(abi.encode(bytes(""),empty),0)),0,false)));
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeCall(posm.modifyLiquidities,(abi.encode(bytes(""),empty),type(uint256).max)),0,true)));
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeCall(posm.modifyLiquiditiesWithoutUnlock,(bytes(""),empty)),0,true)));
        digest=keccak256(abi.encode(digest,callDigest(target,hex"deadbeef",0,false),callDigest(target,"",0,false)));
        for(uint256 n=1;n<4;n++)digest=keccak256(abi.encode(digest,callDigest(target,new bytes(n),0,false)));
        vm.prank(address(manager));bytes32 received=callDigest(target,"",0,true);
        vm.prank(address(weth));digest=keccak256(abi.encode(digest,received,callDigest(target,"",0,true)));
        bytes[] memory calls=new bytes[](3);calls[0]=abi.encodeCall(posm.name,());calls[1]=abi.encodeCall(posm.symbol,());calls[2]=abi.encodeCall(posm.nextTokenId,());
        digest=keccak256(abi.encode(digest,posm.multicall(calls),posm.poolManager(),posm.permit2(),posm.WETH9(),posm.tokenDescriptor(),posm.unsubscribeGasLimit()));
        // A rejected callback must win over a malformed later multicall item.
        bytes[] memory badCalls=new bytes[](2);
        badCalls[0]=abi.encodeCall(posm.unlockCallback,(abi.encode(bytes(""),empty)));
        badCalls[1]=abi.encodeCall(posm.name,());
        bytes memory badMulti=abi.encodeCall(posm.multicall,(badCalls));
        assembly ("memory-safe") {mstore(add(badMulti,132),0xffff)}
        digest=keccak256(abi.encode(digest,callDigest(target,badMulti,0,false)));
        PoolKey memory key=PoolKey(Currency.wrap(address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
        require(posm.initializePool(key,79228162514264337593543950336)==0);
        change(posm,key,abi.encode(key,int24(-600),int24(600),uint256(1000000),type(uint128).max,type(uint128).max,address(1),bytes("")),true,true,false,1000000,false);
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeWithSignature("transferFrom(address,address,uint256)",address(0xbeef),address(0xcafe),1),0,false)));
        posm.subscribe(1,address(subscriber),"");
        posm.permit(address(0xbeef),1,type(uint256).max,513,bytes("1271"));
        require(posm.getApproved(1)==address(0xbeef)&&posm.nonces(address(this),2)==2,"permit integration");
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeWithSignature("permit(address,uint256,uint256,uint256,bytes)",address(0xbeef),1,type(uint256).max,513,bytes("1271")),0,false)));
        posm.permitForAll(address(this),address(0xabcd),true,type(uint256).max,514,bytes("1271"));
        posm.revokeNonce(515);
        require(posm.isApprovedForAll(address(this),address(0xabcd))&&posm.nonces(address(this),2)==14,"operator nonce integration");
        digest=keccak256(abi.encode(digest,posm.DOMAIN_SEPARATOR(),posm.nonces(address(this),2)));
        vm.recordLogs();vm.prank(address(0xbeef));posm.transferFrom(address(this),address(0xcafe),1);
        digest=keccak256(abi.encode(digest,vm.getRecordedLogs(),posm.ownerOf(1),posm.balanceOf(address(this)),posm.balanceOf(address(0xcafe)),posm.getApproved(1),state(manager,posm,key)));
        require(address(posm.subscriber(1))==address(0),"transfer unsubscribes");
        digest=keccak256(abi.encode(digest,callDigest(target,abi.encodeCall(posm.subscribe,(1,address(subscriber),bytes(""))),0,false)));
    }
    function test_guardsAndPublicEntrypoints() public {
        uint256 snap=vm.snapshotState();bytes32 expected=guards(false,false);
        require(vm.revertToState(snap));require(expected==guards(false,true),"position guards parity");
        require(vm.revertToState(snap));require(expected==guards(true,true),"combined guards parity");
    }
    function creditActions(bool fePool,bool fePosition,uint128 seed) internal returns(bytes32 digest) {
        (IPoolManager manager,PositionManager posm)=system(fePool,fePosition);
        PoolKey memory key=PoolKey(Currency.wrap(address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
        manager.initialize(key,79228162514264337593543950336);
        uint256 amount=uint256(seed)%1e18+100;
        bytes[] memory params=new bytes[](5);
        params[0]=abi.encode(key.currency0,amount,true);params[1]=abi.encode(key.currency1,amount,true);
        params[2]=abi.encode(key,int24(-600),int24(600),type(uint128).max,type(uint128).max,address(1),bytes("credits"));
        params[3]=abi.encode(key.currency0);params[4]=abi.encode(key.currency1,type(uint256).max);
        vm.recordLogs();posm.modifyLiquidities(abi.encode(hex"0b0b051213",params),type(uint256).max);
        require(posm.getPositionLiquidity(1)>0,"credit mint");
        digest=state(manager,posm,key);
        params[2]=abi.encode(uint256(1),type(uint128).max,type(uint128).max,bytes("increase credits"));
        params[3]=abi.encode(key.currency0,address(1),uint256(0));params[4]=abi.encode(key.currency1,uint256(0));
        posm.modifyLiquidities(abi.encode(hex"0b0b040e13",params),type(uint256).max);
        digest=keccak256(abi.encode(digest,state(manager,posm,key)));
        bytes[] memory nativeParams=new bytes[](3);nativeParams[0]=abi.encode(uint256(1)<<255);nativeParams[1]=nativeParams[0];nativeParams[2]=abi.encode(address(0),address(1));
        posm.modifyLiquidities{value:amount}(abi.encode(hex"151614",nativeParams),type(uint256).max);
        require(weth.balanceOf(address(posm))==0&&address(posm).balance==0,"wrap unwrap sweep");
        return keccak256(abi.encode(digest,state(manager,posm,key),vm.getRecordedLogs()));
    }
    function testFuzz_creditAndNativeActions(uint128 amount) public {
        uint256 snap=vm.snapshotState();bytes32 expected=creditActions(false,false,amount);
        require(vm.revertToState(snap));require(expected==creditActions(false,true,amount),"credit actions parity");
        require(vm.revertToState(snap));require(expected==creditActions(true,true,amount),"combined credit actions parity");
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory) {
        require(msg.sender==address(callbackManager));
        (bytes memory actions,bytes[] memory params)=abi.decode(data,(bytes,bytes[]));
        callbackPosition.modifyLiquiditiesWithoutUnlock(actions,params);
        return "";
    }
    function withoutUnlock(bool fePool,bool fePosition) internal returns(bytes32) {
        (IPoolManager manager,PositionManager posm)=system(fePool,fePosition);
        callbackManager=manager;callbackPosition=posm;
        PoolKey memory key=PoolKey(Currency.wrap(address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
        manager.initialize(key,79228162514264337593543950336);
        bytes[] memory params=new bytes[](3);
        params[0]=abi.encode(key,int24(-600),int24(600),uint256(1000000),type(uint128).max,type(uint128).max,address(1),bytes("external unlock"));
        params[1]=abi.encode(key.currency0);params[2]=abi.encode(key.currency1);
        vm.recordLogs();manager.unlock(abi.encode(hex"021212",params));
        require(posm.ownerOf(1)==address(this)&&posm.getPositionLiquidity(1)==1000000&&posm.msgSender()==address(0),"external unlock mint");
        return keccak256(abi.encode(state(manager,posm,key),vm.getRecordedLogs()));
    }
    function test_externalUnlock() public {
        uint256 snap=vm.snapshotState();bytes32 expected=withoutUnlock(false,false);
        require(vm.revertToState(snap));require(expected==withoutUnlock(false,true),"external unlock parity");
        require(vm.revertToState(snap));require(expected==withoutUnlock(true,true),"combined external unlock parity");
    }
    function test_referenceLifecycle() public {
        uint256 snap=vm.snapshotState();
        run(false,false,Case(1e15,false,false,true,1000000));
        require(vm.revertToState(snap));
        run(false,false,Case(1e15,true,false,true,1000000));
        require(vm.revertToState(snap));
        run(false,false,Case(1e15,false,true,false,0));
        require(vm.revertToState(snap));guards(false,false);
        require(vm.revertToState(snap));creditActions(false,false,1e15);
        require(vm.revertToState(snap));withoutUnlock(false,false);
    }
    function testFuzz_lifecycle(uint128 liquidity,bool native,bool reject,bool subscribed,uint64 donated) public {
        Case memory c=Case(liquidity,native,reject,subscribed,donated);uint256 snap=vm.snapshotState();bytes32 expected=run(false,false,c);
        require(vm.revertToState(snap));bytes32 port=run(false,true,c);require(expected==port,"Fe PositionManager/Solidity PoolManager");
        require(vm.revertToState(snap));bytes32 complete=run(true,true,c);require(expected==complete,"Fe PositionManager/Fe PoolManager");
    }
    function initializeMintMulticall(bool fePool,bool fePosition,uint128 rawLiquidity,bool native,bool reject,int16 rawTick) internal returns(bytes32) {
        (IPoolManager manager,PositionManager posm)=system(fePool,fePosition);
        PoolKey memory key=PoolKey(Currency.wrap(native?address(0):address(low)),Currency.wrap(address(high)),3000,60,IHooks(address(0)));
        int24 tick=int24(rawTick)%301;uint256 liquidity=uint256(rawLiquidity)%1e18+1000000;
        bytes32 beforeState=state(manager,posm,key);
        bytes[] memory params=new bytes[](3);
        params[0]=abi.encode(key,int24(-600),int24(600),liquidity,reject?uint128(0):type(uint128).max,type(uint128).max,address(1),bytes("atomic mint"));
        params[1]=abi.encode(key.currency0,key.currency1);params[2]=abi.encode(Currency.wrap(address(0)),address(1));
        bytes[] memory calls=new bytes[](3);
        calls[0]=abi.encodeCall(posm.initializePool,(key,TickMath.getSqrtPriceAtTick(tick)));
        calls[1]=calls[0]; // A duplicate initialize is caught and returns int24.max.
        calls[2]=abi.encodeCall(posm.modifyLiquidities,(abi.encode(hex"020d14",params),type(uint256).max));
        vm.recordLogs();
        (bool ok,bytes memory out)=address(posm).call{value:native?1e22:0}(abi.encodeCall(posm.multicall,(calls)));
        Vm.Log[] memory logs=vm.getRecordedLogs();
        require(ok!=reject,"atomic initialize/mint status");
        if(ok) {
            bytes[] memory results=abi.decode(out,(bytes[]));
            require(results.length==3&&abi.decode(results[0],(int24))==tick&&abi.decode(results[1],(int24))==type(int24).max&&results[2].length==0,"initializer multicall results");
            require(posm.ownerOf(1)==address(this)&&posm.getPositionLiquidity(1)==liquidity&&posm.nextTokenId()==2,"atomic mint state");
            require(address(posm).balance==0,"native remainder swept");
        } else require(state(manager,posm,key)==beforeState,"mint failure must also roll back pool creation and value");
        require(posm.msgSender()==address(0),"multicall locker clear");
        require(manager.exttload(0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23)==0,"manager relocked");
        require(manager.exttload(0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b)==0,"all deltas settled");
        return keccak256(abi.encode(ok,out,logs,state(manager,posm,key)));
    }
    function testFuzz_initializeMintMulticall(uint128 liquidity,bool native,bool reject,int16 tick) public {
        uint256 snap=vm.snapshotState();bytes32 expected=initializeMintMulticall(false,false,liquidity,native,reject,tick);
        require(vm.revertToState(snap));require(initializeMintMulticall(false,true,liquidity,native,reject,tick)==expected,"initialize/mint Fe NFT parity");
        require(vm.revertToState(snap));require(initializeMintMulticall(true,true,liquidity,native,reject,tick)==expected,"initialize/mint full Fe parity");
    }

}
