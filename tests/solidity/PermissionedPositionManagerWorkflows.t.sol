// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PermissionedPositionManager} from "./periphery/src/hooks/permissionedPools/PermissionedPositionManager.sol";
import {IPositionDescriptor} from "./periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "./periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "./permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolManager} from "./reference/src/PoolManager.sol";
import {IPoolManager} from "./reference/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./reference/src/types/PoolKey.sol";
import {Currency} from "./reference/src/types/Currency.sol";
import {IHooks} from "./reference/src/interfaces/IHooks.sol";
import {PermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/PermissionsAdapterFactory.sol";
import {IPermissionsAdapterFactory} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol";
import {IPermissionsAdapter,IERC20} from "./periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {IAllowlistChecker} from "./periphery/src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol";
import {PermissionFlag} from "./periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
interface Vm {
    struct Log {bytes32[] topics;bytes data;address emitter;}
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
    function prank(address) external;
    function etch(address,bytes calldata) external;
    function snapshotState() external returns(uint256);
    function revertToState(uint256) external returns(bool);
    function recordLogs() external;
    function getRecordedLogs() external returns(Log[] memory);
}
contract PositionAsset {
    mapping(address=>uint256) public balanceOf;
    mapping(address=>mapping(address=>uint256)) public allowance;
    mapping(address=>bool) public denied;
    event Transfer(address indexed from,address indexed to,uint256 amount);
    function mint(address to,uint256 amount) external {balanceOf[to]+=amount;}
    function deny(address to,bool value) external {denied[to]=value;}
    function approve(address to,uint256 amount) external returns(bool){allowance[msg.sender][to]=amount;return true;}
    function transfer(address to,uint256 amount) external returns(bool){move(msg.sender,to,amount);return true;}
    function transferFrom(address from,address to,uint256 amount) external returns(bool){
        if(allowance[from][msg.sender]!=type(uint256).max)allowance[from][msg.sender]-=amount;
        move(from,to,amount);return true;
    }
    function move(address from,address to,uint256 amount) internal {
        require(!denied[to],"issuer transfer restriction");balanceOf[from]-=amount;balanceOf[to]+=amount;emit Transfer(from,to,amount);
    }
}
contract PositionAllowlist is IAllowlistChecker {
    bytes2 public flags=0xffff;mapping(address=>bool) public denied;
    function set(bytes2 value) external {flags=value;}
    function deny(address who,bool value) external {denied[who]=value;}
    function supportsInterface(bytes4 id) external pure returns(bool){return id==0x01ffc9a7||id==type(IAllowlistChecker).interfaceId;}
    function checkAllowlist(address who,address) external view returns(PermissionFlag){return PermissionFlag.wrap(denied[who]?bytes2(0):flags);}
}
// Read-only adversarial ABI responses; original contract code is restored
// before checking persistent invariants. No reference source is modified.
contract PermissionReadResponse {
    uint8 immutable shape;uint256 immutable value;
    constructor(uint8 s,uint256 v){shape=s;value=v;}
    fallback() external {
        uint8 s=shape;uint256 v=value;
        assembly ("memory-safe") {
            mstore(0,v)
            switch s
            case 0 {return(0,0)}
            case 1 {return(0,31)}
            case 2 {mstore(0,not(0)) return(0,32)}
            case 3 {mstore(32,not(0)) return(0,33)}
            case 4 {mstore(0,0xcafe) revert(30,2)}
            default {return(0,32)}
        }
    }
}
contract PositionLp {
    bool public rejectNative;IPoolManager manager;uint8 grief;
    function reject(bool value) external {rejectNative=value;}
    function configureGrief(IPoolManager m,uint8 mode) external {manager=m;grief=mode;}
    receive() external payable {
        require(!rejectNative,"LP native denied");
        if(grief==1){assembly ("memory-safe") {invalid()}}
        if(grief==2)manager.mint(address(this),0,1);
    }
}
contract ReattachingSubscriber {
    uint256 public subscriptions;uint256 public unsubscriptions;
    function notifySubscribe(uint256,bytes calldata) external {subscriptions++;}
    function notifyUnsubscribe(uint256 id) external {
        unsubscriptions++;
        PermissionedPositionManager posm=PermissionedPositionManager(payable(msg.sender));
        // This callback is outside the manager unlock, but inside the NFT lock.
        require(posm.poolManager().exttload(0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23)==0,"unsubscribe while manager locked");
        posm.subscribe(id,address(this),"reattach");
    }
    function notifyBurn(uint256,address,uint256,uint256,int256) external pure {revert("must not notify burn");}
    function notifyModifyLiquidity(uint256,int256,int256) external pure {}
}
contract PermissionedPositionManagerWorkflowsTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 constant LOCK=0xc090fc4683624cfc3884e9d8de5eca132f2d0ec062aff75d43c0465d5ceeab23;
    bytes32 constant COUNT=0x7d4b3164c6e45b97e7d87b7125a44c5828d005af88f9d751cfd78729c5d99a0b;
    PositionAsset a;PositionAsset b;PositionAllowlist checker;PositionLp lp;
    IAllowanceTransfer permit;bytes managerCode;bytes positionCode;bytes factoryCode;
    receive() external payable {}
    function deploy(bytes memory code) internal returns(address addr){
        assembly ("memory-safe") {addr:=create(0,add(code,32),mload(code))}require(addr.code.length>0,"Fe deployment");
    }
    function setUp() public {
        a=new PositionAsset();b=new PositionAsset();checker=new PositionAllowlist();lp=new PositionLp();
        permit=IAllowanceTransfer(deploy(vm.parseBytes(vm.readFile("permit2-bytecode.txt"))));
        managerCode=vm.parseBytes(vm.readFile("manager-bytecode.txt"));positionCode=vm.parseBytes(vm.readFile("fe-bytecode.txt"));factoryCode=vm.parseBytes(vm.readFile("permissions-factory-bytecode.txt"));
        a.mint(address(this),1e30);b.mint(address(this),1e30);vm.deal(address(this),1e30);
        a.approve(address(permit),type(uint256).max);b.approve(address(permit),type(uint256).max);
    }
    struct System {IPoolManager manager;PermissionedPositionManager posm;IPermissionsAdapterFactory factory;address adapterA;address adapterB;PoolKey key;}
    function system(bool feManager,bool fePosition,bool native,uint256 deliveryGas) internal returns(System memory s){
        s.manager=feManager?IPoolManager(deploy(bytes.concat(managerCode,abi.encode(address(this))))):IPoolManager(address(new PoolManager(address(this))));
        s.factory=feManager?IPermissionsAdapterFactory(deploy(bytes.concat(factoryCode,abi.encode(s.manager)))):IPermissionsAdapterFactory(address(new PermissionsAdapterFactory(address(s.manager))));
        s.posm=fePosition?PermissionedPositionManager(payable(deploy(bytes.concat(positionCode,abi.encode(s.manager,permit,500000,address(0),address(0),s.factory,deliveryGas)))))
            :new PermissionedPositionManager(s.manager,permit,500000,IPositionDescriptor(address(0)),IWETH9(address(0)),s.factory,deliveryGas);
        s.adapterA=s.factory.createPermissionsAdapter(IERC20(address(a)),address(this),checker);
        s.adapterB=s.factory.createPermissionsAdapter(IERC20(address(b)),address(this),checker);
        a.mint(s.adapterA,1);b.mint(s.adapterB,1);s.factory.verifyPermissionsAdapter(s.adapterA);s.factory.verifyPermissionsAdapter(s.adapterB);
        address[2] memory adapters=[s.adapterA,s.adapterB];
        for(uint256 i;i<2;i++){
            IPermissionsAdapter(adapters[i]).updateAllowedWrapper(address(s.posm),true);
            IPermissionsAdapter(adapters[i]).updateAllowedHook(IHooks(address(0)),true);
        }
        permit.approve(address(a),address(s.posm),type(uint160).max,type(uint48).max);
        permit.approve(address(b),address(s.posm),type(uint160).max,type(uint48).max);
        address left=native?address(0):s.adapterA;address right=s.adapterB;
        if(left>right)(left,right)=(right,left);
        s.key=PoolKey(Currency.wrap(left),Currency.wrap(right),3000,60,IHooks(address(0)));
        s.manager.initialize(s.key,79228162514264337593543950336);
        require(keccak256(bytes(s.posm.name()))==keccak256("Uniswap v4 Permissioned Positions NFT"),"name");
        require(keccak256(bytes(s.posm.symbol()))==keccak256("UNI-V4-PERM-POSM"),"symbol");
        require(address(s.posm.PERMISSIONS_ADAPTER_FACTORY())==address(s.factory)&&s.posm.DELIVERY_GAS_LIMIT()==deliveryGas,"immutables");
    }
    function change(System memory s,bytes1 action,bytes memory params,bool inflow,bool native) internal returns(bool ok,bytes memory out){
        bytes[] memory p=new bytes[](3);p[0]=params;
        p[1]=inflow?abi.encode(s.key.currency0,s.key.currency1):abi.encode(s.key.currency0,s.key.currency1,address(1));
        p[2]=abi.encode(Currency.wrap(address(0)),address(1));
        bytes memory actions=abi.encodePacked(action,inflow?bytes1(0x0d):bytes1(0x11),bytes1(0x14));
        return address(s.posm).call{value:inflow&&native?1e22:0}(abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(actions,p),type(uint256).max)));
    }
    function mint(System memory s,uint256 liquidity,bool native,address owner) internal {
        (bool ok,)=change(s,0x02,abi.encode(s.key,int24(-600),int24(600),liquidity,type(uint128).max,type(uint128).max,owner,bytes("mint")),true,native);
        require(ok&&s.posm.ownerOf(1)==owner&&s.posm.getPositionLiquidity(1)==liquidity,"mint");
    }
    function clean(System memory s) internal view {
        require(s.posm.msgSender()==address(0),"position lock");
        require(s.manager.exttload(LOCK)==0&&s.manager.exttload(COUNT)==0,"manager settled");
        require(s.manager.exttload(keccak256(abi.encode(address(s.posm),s.key.currency0)))==0,"currency0 settled");
        require(s.manager.exttload(keccak256(abi.encode(address(s.posm),s.key.currency1)))==0,"currency1 settled");
        for(uint256 i;i<2;i++){
            address adapter=i==0?s.adapterA:s.adapterB;PositionAsset token=i==0?a:b;
            uint256 supply=IERC20(adapter).totalSupply();
            require(IERC20(adapter).balanceOf(address(s.manager))==supply,"sole PoolManager holder");
            require(token.balanceOf(adapter)>=supply,"adapter backing");
        }
    }
    function digest(System memory s,bytes memory extra) internal returns(bytes32){
        clean(s);Vm.Log[] memory logs=vm.getRecordedLogs();
        bytes32 position=keccak256(abi.encode(s.posm.positionInfo(1),s.posm.nextTokenId(),s.posm.getPositionLiquidity(1)));
        bytes32 assets=keccak256(abi.encode(a.balanceOf(address(this)),b.balanceOf(address(this)),a.balanceOf(address(lp)),b.balanceOf(address(lp)),address(lp).balance));
        bytes32 claims=keccak256(abi.encode(s.manager.balanceOf(address(this),uint160(s.adapterA)),s.manager.balanceOf(address(this),uint160(s.adapterB)),
            s.manager.balanceOf(address(lp),0),s.manager.balanceOf(address(s.posm),uint160(s.adapterA)),s.manager.balanceOf(address(s.posm),uint160(s.adapterB))));
        return keccak256(abi.encode(extra,logs,position,assets,claims));
    }
    function lifecycle(bool feManager,bool fePosition,uint256 liq,bool native,uint8 revoke) internal returns(bytes32){
        System memory s=system(feManager,fePosition,native,500000);vm.recordLogs();mint(s,liq,native,address(this));
        if(revoke==1)checker.set(0);
        if(revoke==2)IPermissionsAdapter(s.adapterB).updateAllowedHook(IHooks(address(0)),false);
        (bool ok,bytes memory out)=change(s,0x00,abi.encode(uint256(1),liq/2,type(uint128).max,type(uint128).max,bytes("increase")),true,native);
        require(ok==(revoke==0),"increase permission");
        bytes memory outcome=abi.encode(ok,out);
        (ok,out)=change(s,0x03,abi.encode(uint256(1),uint128(0),uint128(0),bytes("exit")),false,native);
        require(ok,"exit remains open after revocation");
        return digest(s,abi.encode(outcome,out));
    }
    function testFuzz_lifecycle(uint128 amount,bool native,uint8 revoke) public {
        uint256 liq=uint256(amount)%1e18+100;revoke%=3;
        uint256 snap=vm.snapshotState();bytes32 expected=lifecycle(false,false,liq,native,revoke);require(vm.revertToState(snap));
        snap=vm.snapshotState();require(lifecycle(false,true,liq,native,revoke)==expected,"Fe position lifecycle");require(vm.revertToState(snap));
        require(lifecycle(true,true,liq,native,revoke)==expected,"all Fe lifecycle");
    }
    function forced(bool feManager,bool fePosition,uint256 liq,bool native,uint8 rejection,bool gasFallback) internal returns(bytes32){
        System memory s=system(feManager,fePosition,native,gasFallback?0:500000);mint(s,liq,native,address(lp));
        if(rejection>0){a.deny(address(lp),true);b.deny(address(lp),true);lp.reject(true);}
        if(rejection>1){a.deny(address(this),true);b.deny(address(this),true);}
        checker.set(0); // Forced exit does not depend on current LP permission.
        vm.recordLogs();s.posm.unwindPosition(1,0,0,"forced exit");
        require(s.posm.balanceOf(address(lp))==0&&s.posm.getApproved(1)==address(0),"NFT teardown");
        require(s.manager.balanceOf(address(s.posm),uint160(s.adapterA))==0&&s.manager.balanceOf(address(s.posm),uint160(s.adapterB))==0,"no stranded adapter claims");
        uint256 claim=s.manager.balanceOf(address(this),uint160(s.adapterB));
        if(rejection==2||gasFallback)require(claim>0,"admin claim fallback");
        else require(claim==0,"real asset delivery");
        bytes32 first=digest(s,abi.encode(claim));
        if(claim>0){
            a.deny(address(this),false);b.deny(address(this),false);s.manager.setOperator(address(s.posm),true);
            s.posm.withdrawClaim(Currency.wrap(s.adapterB),claim,address(1));
            require(s.manager.balanceOf(address(this),uint160(s.adapterB))==0,"claim withdrawal");
        }
        return keccak256(abi.encode(first,digest(s,"withdrawn")));
    }
    function testFuzz_forcedExit(uint128 amount,bool native,uint8 rejection,bool gasFallback) public {
        uint256 liq=uint256(amount)%1e18+10000;rejection%=3;
        uint256 snap=vm.snapshotState();bytes32 expected=forced(false,false,liq,native,rejection,gasFallback);require(vm.revertToState(snap));
        snap=vm.snapshotState();require(forced(false,true,liq,native,rejection,gasFallback)==expected,"Fe position forced exit");require(vm.revertToState(snap));
        require(forced(true,true,liq,native,rejection,gasFallback)==expected,"all Fe forced exit");
    }
    function testFuzz_stateful(uint256 seed,bool native) public {
        uint256 snap=vm.snapshotState();bytes32 expected=stateful(false,false,seed,native);require(vm.revertToState(snap));
        snap=vm.snapshotState();require(stateful(false,true,seed,native)==expected,"Fe stateful parity");require(vm.revertToState(snap));
        require(stateful(true,true,seed,native)==expected,"all Fe stateful parity");
    }
    function stateful(bool feManager,bool fePosition,uint256 seed,bool native) internal returns(bytes32 trace){
        System memory s=system(feManager,fePosition,native,500000);mint(s,1000000,native,address(this));
        bool hookAllowed=true;bool allowed=true;vm.recordLogs();
        for(uint256 step;step<16;step++){
            seed=uint256(keccak256(abi.encode(seed,step)));uint256 op=seed%5;
            uint256 beforeLiquidity=s.posm.getPositionLiquidity(1);bool ok=true;bytes memory out;
            if(op==0){
                uint256 amount=(seed>>64)%1000+1;
                (ok,out)=change(s,0x00,abi.encode(uint256(1),amount,type(uint128).max,type(uint128).max,bytes("")),true,native);
                require(ok==(allowed&&hookAllowed),"stateful increase admission");
                require(s.posm.getPositionLiquidity(1)==beforeLiquidity+(ok?amount:0),"increase liquidity accounting");
            }else if(op==1){
                uint256 amount=(seed>>64)%beforeLiquidity;
                (ok,out)=change(s,0x01,abi.encode(uint256(1),amount,uint128(0),uint128(0),bytes("")),false,native);
                require(ok&&s.posm.getPositionLiquidity(1)==beforeLiquidity-amount,"decrease remains available");
            }else if(op==2){allowed=(seed>>8)&1==1;checker.set(allowed?bytes2(0xffff):bytes2(0));}
            else if(op==3){hookAllowed=(seed>>8)&1==1;IPermissionsAdapter(s.adapterB).updateAllowedHook(IHooks(address(0)),hookAllowed);}
            else {
                b.mint(address(s.posm),(seed>>64)%10000+1);
                uint256 held=b.balanceOf(address(s.posm));uint256 beforeClaim=s.manager.balanceOf(address(s.posm),uint160(s.adapterB));
                bytes[] memory params=new bytes[](2);params[0]=abi.encode(Currency.wrap(s.adapterB),uint256(1)<<255,false);params[1]=abi.encode(Currency.wrap(s.adapterB));
                (ok,out)=address(s.posm).call(abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(hex"0b17",params),type(uint256).max)));
                require(ok==allowed,"self-funding liquidity permission");
                require(b.balanceOf(address(s.posm))==(ok?0:held),"contract balance maps underlying");
                require(s.manager.balanceOf(address(s.posm),uint160(s.adapterB))==beforeClaim+(ok?held:0),"claim backing accounting");
            }
            require(s.posm.ownerOf(1)==address(this),"stateful owner");
            trace=digest(s,abi.encode(trace,step,ok,out,allowed,hookAllowed,b.balanceOf(address(s.posm))));
        }
        s.posm.unwindPosition(1,0,0,"");
        require(s.posm.balanceOf(address(this))==0&&s.manager.balanceOf(address(s.posm),uint160(s.adapterB))==0,"stateful final exit");
        return digest(s,abi.encode(trace));
    }
    function parkClaims(System memory s,uint256 amount,bool native) internal {
        bytes[] memory params=new bytes[](4);
        params[0]=abi.encode(s.key.currency0,amount,true);params[1]=abi.encode(s.key.currency0);
        params[2]=abi.encode(s.key.currency1,amount,true);params[3]=abi.encode(s.key.currency1);
        s.posm.modifyLiquidities{value:native?amount:0}(abi.encode(hex"0b170b17",params),type(uint256).max);
        require(s.manager.balanceOf(address(s.posm),uint160(Currency.unwrap(s.key.currency0)))==amount,"parked currency0");
        require(s.manager.balanceOf(address(s.posm),uint160(Currency.unwrap(s.key.currency1)))==amount,"parked currency1");
        clean(s);
    }
    function testFuzz_strayClaims(uint128 extra,bool native,bool claimFallback) public {
        uint256 amount=uint256(extra)%1e15+1;
        uint256 snap=vm.snapshotState();bytes32 expected=stray(false,false,amount,native,claimFallback);require(vm.revertToState(snap));
        snap=vm.snapshotState();require(stray(false,true,amount,native,claimFallback)==expected,"Fe stray claims");require(vm.revertToState(snap));
        require(stray(true,true,amount,native,claimFallback)==expected,"all Fe stray claims");
    }
    function stray(bool feManager,bool fePosition,uint256 amount,bool native,bool claimFallback) internal returns(bytes32){
        System memory s=system(feManager,fePosition,native,claimFallback?0:500000);mint(s,1e12,native,address(lp));parkClaims(s,amount,native);
        vm.recordLogs();s.posm.unwindPosition(1,0,0,"");
        for(uint256 i;i<2;i++){
            Currency c=i==0?s.key.currency0:s.key.currency1;uint256 id=uint160(Currency.unwrap(c));
            require(s.manager.balanceOf(address(s.posm),id)==0,"all pre-existing claims delivered");
            if(claimFallback)require(s.manager.balanceOf(id==0?address(lp):address(this),id)>amount,"burn and stray claims included");
        }
        if(!claimFallback){require(b.balanceOf(address(lp))>amount,"underlying stray delivery");if(native)require(address(lp).balance>amount,"native stray delivery");}
        return digest(s,abi.encode(amount));
    }
    function test_claimActionsAndRawRecipient() public {
        uint256 snap=vm.snapshotState();bytes32 expected=claimActions(false);require(vm.revertToState(snap));require(claimActions(true)==expected,"claim action parity");
    }
    function claimActions(bool fePosition) internal returns(bytes32){
        System memory s=system(false,fePosition,false,500000);parkClaims(s,12345,false);vm.recordLogs();
        bytes[] memory params=new bytes[](1);params[0]=abi.encode(s.key.currency0,address(0xbad),uint256(0));
        (bool ok,bytes memory out)=address(s.posm).call(abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(hex"18",params),type(uint256).max)));
        require(!ok&&bytes4(out)==bytes4(keccak256("Unauthorized()")),"claim sender checked even for zero");
        params[0]=abi.encode(s.key.currency0,address(2),uint256(12345));
        s.posm.modifyLiquidities(abi.encode(hex"19",params),type(uint256).max);
        PositionAsset token=PositionAsset(s.factory.verifiedPermissionsAdapterOf(Currency.unwrap(s.key.currency0)));
        require(token.balanceOf(address(2))==12345&&token.balanceOf(address(s.posm))==0,"unwind primitive keeps literal recipient");
        return digest(s,out);
    }
    function test_isolatedMaliciousNativeDelivery() public {
        for(uint8 mode=1;mode<=2;mode++){
            uint256 snap=vm.snapshotState();bytes32 expected=maliciousDelivery(false,mode);require(vm.revertToState(snap));
            snap=vm.snapshotState();require(maliciousDelivery(true,mode)==expected,"isolated delivery parity");require(vm.revertToState(snap));
        }
    }
    function maliciousDelivery(bool fePosition,uint8 mode) internal returns(bytes32){
        System memory s=system(false,fePosition,true,500000);mint(s,1e12,true,address(lp));lp.configureGrief(s.manager,mode);
        vm.recordLogs();s.posm.unwindPosition(1,0,0,"");
        uint256 amount=s.manager.balanceOf(address(lp),0);
        require(amount>0&&address(lp).balance==0,"native leg rolled back into LP claim");
        require(s.manager.balanceOf(address(s.posm),0)==0,"no stranded native claim");
        bytes32 initial=digest(s,abi.encode(amount));
        vm.prank(address(lp));s.manager.setOperator(address(s.posm),true);
        uint256 beforeBalance=address(this).balance;
        vm.prank(address(lp));s.posm.withdrawClaim(Currency.wrap(address(0)),amount,address(this));
        require(address(this).balance==beforeBalance+amount&&s.manager.balanceOf(address(lp),0)==0,"claim remains withdrawable");
        return keccak256(abi.encode(initial,digest(s,"")));
    }
    function test_permissionReadResponses() public {
        for(uint8 shape;shape<6;shape++)for(uint8 target;target<2;target++){
            uint256 snap=vm.snapshotState();bytes32 expected=permissionRead(false,shape,target==1);require(vm.revertToState(snap));
            snap=vm.snapshotState();require(permissionRead(true,shape,target==1)==expected,"permission response parity");require(vm.revertToState(snap));
        }
    }
    function permissionRead(bool fePosition,uint8 shape,bool adapter) internal returns(bytes32){
        System memory s=system(false,fePosition,false,500000);mint(s,10000,false,address(this));
        address target=adapter?s.adapterB:address(s.factory);bytes memory original=target.code;
        vm.etch(target,address(new PermissionReadResponse(shape,adapter?1:0)).code);
        vm.recordLogs();(bool ok,bytes memory out)=change(s,0x00,abi.encode(uint256(1),uint256(0),type(uint128).max,type(uint128).max,bytes("")),true,false);
        require(ok==(shape==3||shape==5),"response shape status");
        if(shape==4)require(keccak256(out)==keccak256(hex"cafe"),"read revert propagation");
        vm.etch(target,original);
        return digest(s,abi.encode(ok,out));
    }
    function test_admission() public {
        for(uint8 issue;issue<5;issue++){
            uint256 snap=vm.snapshotState();bytes32 expected=admission(false,issue);require(vm.revertToState(snap));
            snap=vm.snapshotState();require(admission(true,issue)==expected,"admission parity");require(vm.revertToState(snap));
        }
    }
    function admission(bool fePosition,uint8 issue) internal returns(bytes32){
        System memory s=system(false,fePosition,false,500000);
        bytes4 expected;
        if(issue==0){s.key.currency0=Currency.wrap(address(a));s.key.currency1=Currency.wrap(address(b));expected=PermissionedPositionManager.NoVerifiedAdapter.selector;}
        if(issue==1){s.key.currency0=Currency.wrap(s.factory.createPermissionsAdapter(IERC20(address(a)),address(this),checker));expected=PermissionedPositionManager.NoVerifiedAdapter.selector;}
        if(issue==2){s.key.currency0=Currency.wrap(address(0x42));expected=PermissionedPositionManager.NonContractCurrency.selector;}
        if(issue==3){IPermissionsAdapter(s.adapterB).updateAllowedHook(IHooks(address(0)),false);expected=PermissionedPositionManager.InvalidHook.selector;}
        if(issue==4){checker.set(0);expected=bytes4(keccak256("Unauthorized()"));}
        vm.recordLogs();(bool ok,bytes memory out)=change(s,0x02,abi.encode(s.key,int24(-600),int24(600),uint256(10000),type(uint128).max,type(uint128).max,address(1),bytes("")),true,false);
        require(!ok&&bytes4(out)==expected,"admission reason");require(s.posm.nextTokenId()==1,"admission rollback");
        return digest(s,out);
    }
    function test_ownerAndFundingPermissions() public {
        uint256 snap=vm.snapshotState();bytes32 expected=rolePermissions(false);require(vm.revertToState(snap));require(rolePermissions(true)==expected,"owner and payer role parity");
    }
    function rolePermissions(bool fePosition) internal returns(bytes32 trace){
        System memory s=system(false,fePosition,true,500000);checker.deny(address(lp),true);vm.recordLogs();
        // Entirely native-funded one-sided liquidity still validates the owner
        // against the unused permissioned currency before minting the NFT.
        (bool ok,bytes memory out)=change(s,0x02,abi.encode(s.key,int24(600),int24(1200),uint256(1e12),type(uint128).max,type(uint128).max,address(lp),bytes("")),true,true);
        require(!ok&&bytes4(out)==bytes4(keccak256("Unauthorized()")),"one-sided owner authorization");trace=keccak256(out);
        checker.deny(address(lp),false);checker.deny(address(this),true);
        (ok,out)=change(s,0x02,abi.encode(s.key,int24(-600),int24(600),uint256(1e12),type(uint128).max,type(uint128).max,address(lp),bytes("")),true,true);
        require(!ok&&bytes4(out)==bytes4(keccak256("Unauthorized()")),"actual funding actor authorization");trace=keccak256(abi.encode(trace,out));
        checker.deny(address(this),false);mint(s,1e12,true,address(lp));vm.prank(address(lp));s.posm.approve(address(this),1);
        for(uint256 mode;mode<2;mode++){
            checker.deny(address(lp),mode==0);checker.deny(address(this),mode==1);
            (ok,out)=change(s,0x00,abi.encode(uint256(1),uint256(1e12),type(uint128).max,type(uint128).max,bytes("")),true,true);
            require(!ok&&bytes4(out)==bytes4(keccak256("Unauthorized()")),"increase validates owner then actor");trace=keccak256(abi.encode(trace,out));
        }
        checker.deny(address(lp),true);
        (ok,out)=change(s,0x03,abi.encode(uint256(1),uint128(0),uint128(0),bytes("")),false,true);
        require(ok,"revoked owner and operator can exit");trace=keccak256(abi.encode(trace,out));
        checker.deny(address(this),false);checker.deny(address(1),true);
        (ok,out)=change(s,0x02,abi.encode(s.key,int24(-600),int24(600),uint256(1e12),type(uint128).max,type(uint128).max,address(1),bytes("")),true,true);
        require(ok&&s.posm.ownerOf(2)==address(this),"mint checks mapped recipient");
        return digest(s,abi.encode(trace,out));
    }
    function test_increaseAuthorizationOrder() public {
        uint256 snap=vm.snapshotState();bytes32 expected=increaseOrder(false);require(vm.revertToState(snap));require(increaseOrder(true)==expected,"increase order parity");
    }
    function increaseOrder(bool fePosition) internal returns(bytes32 trace){
        System memory s=system(false,fePosition,false,500000);mint(s,10000,false,address(this));checker.set(0);
        for(uint256 i;i<2;i++){
            bytes[] memory params=new bytes[](1);
            params[0]=i==0?abi.encode(uint256(1),uint256(1),type(uint128).max,type(uint128).max,bytes("")):abi.encode(uint256(1),type(uint128).max,type(uint128).max,bytes(""));
            vm.prank(address(0xbad));(bool ok,bytes memory out)=address(s.posm).call(abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(i==0?hex"00":hex"04",params),type(uint256).max)));
            require(!ok&&bytes4(out)==bytes4(keccak256("Unauthorized()")),"owner permission before approval");trace=keccak256(abi.encode(trace,out));
        }
        clean(s);
    }
    function test_subscriberReattachmentCleanup() public {
        uint256 snap=vm.snapshotState();bytes32 expected=reattachment(false);require(vm.revertToState(snap));require(reattachment(true)==expected,"reattachment parity");
    }
    function reattachment(bool fePosition) internal returns(bytes32){
        System memory s=system(false,fePosition,false,500000);mint(s,10000,false,address(this));
        ReattachingSubscriber subscriber=new ReattachingSubscriber();s.posm.approve(address(subscriber),1);s.posm.subscribe(1,address(subscriber),"");
        vm.recordLogs();s.posm.unwindPosition(1,0,0,"");
        require(subscriber.subscriptions()==2&&subscriber.unsubscriptions()==1,"single unsubscribe callback");
        require(address(s.posm.subscriber(1))==address(0),"reattached subscriber cleared");
        return digest(s,"");
    }
    function isValidSignature(bytes32,bytes calldata) external pure returns(bytes4){return 0x1626ba7e;}
    function callDigest(address target,bytes memory data,uint256 value,bool success) internal returns(bytes32){
        (bool ok,bytes memory out)=target.call{value:value}(data);require(ok==success,"inherited call status");return keccak256(abi.encode(ok,out));
    }
    function test_zeroFactoryIsNotDisabledMode() public {
        uint256 snap=vm.snapshotState();bytes32 expected=zeroFactory(false);require(vm.revertToState(snap));require(zeroFactory(true)==expected,"zero factory parity");
    }
    function zeroFactory(bool fePosition) internal returns(bytes32){
        IPoolManager manager=IPoolManager(address(new PoolManager(address(this))));
        PermissionedPositionManager posm=fePosition?PermissionedPositionManager(payable(deploy(bytes.concat(positionCode,abi.encode(manager,permit,500000,address(0),address(0),address(0),500000)))))
            :new PermissionedPositionManager(manager,permit,500000,IPositionDescriptor(address(0)),IWETH9(address(0)),IPermissionsAdapterFactory(address(0)),500000);
        bytes[] memory params=new bytes[](1);params[0]=abi.encode(Currency.wrap(address(0)),address(1));
        (bool ok,bytes memory out)=address(posm).call(abi.encodeCall(posm.modifyLiquidities,(abi.encode(hex"14",params),type(uint256).max)));
        require(!ok&&out.length==0,"zero factory read must fail");bytes32 first=keccak256(abi.encode(ok,out));
        (ok,out)=address(posm).call(abi.encodeCall(posm.unwindPosition,(uint256(999),uint128(0),uint128(0),bytes(""))));
        require(!ok&&out.length==0&&posm.msgSender()==address(0),"factory read precedes NFT existence");
        return keccak256(abi.encode(first,ok,out));
    }
    function test_inheritedEntrypointsAndPermits() public {
        uint256 snap=vm.snapshotState();bytes32 expected=inherited(false);require(vm.revertToState(snap));require(inherited(true)==expected,"inherited parity");
    }
    function inherited(bool fePosition) internal returns(bytes32 trace){
        System memory s=system(false,fePosition,false,500000);address target=address(s.posm);bytes[] memory empty=new bytes[](0);
        trace=callDigest(target,abi.encodeCall(s.posm.unlockCallback,(abi.encode(bytes(""),empty))),0,false);
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(bytes(""),empty),0)),0,false)));
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeCall(s.posm.modifyLiquidities,(abi.encode(bytes(""),empty),type(uint256).max)),0,true)));
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeCall(s.posm.modifyLiquiditiesWithoutUnlock,(bytes(""),empty)),0,true)));
        trace=keccak256(abi.encode(trace,callDigest(target,hex"deadbeef",0,false),callDigest(target,"",0,false)));
        for(uint256 n=1;n<4;n++)trace=keccak256(abi.encode(trace,callDigest(target,new bytes(n),0,false)));
        vm.prank(address(s.manager));bytes32 received=callDigest(target,"",0,true);trace=keccak256(abi.encode(trace,received));
        bytes[] memory calls=new bytes[](3);calls[0]=abi.encodeCall(s.posm.name,());calls[1]=abi.encodeCall(s.posm.symbol,());calls[2]=abi.encodeCall(s.posm.nextTokenId,());
        trace=keccak256(abi.encode(trace,s.posm.multicall(calls),s.posm.poolManager(),s.posm.permit2(),s.posm.WETH9(),s.posm.tokenDescriptor(),s.posm.unsubscribeGasLimit()));
        bytes[] memory bad=new bytes[](2);bad[0]=abi.encodeCall(s.posm.unlockCallback,(abi.encode(bytes(""),empty)));bad[1]=abi.encodeCall(s.posm.name,());
        bytes memory malformed=abi.encodeCall(s.posm.multicall,(bad));assembly ("memory-safe") {mstore(add(malformed,132),0xffff)}
        trace=keccak256(abi.encode(trace,callDigest(target,malformed,0,false)));
        mint(s,1000000,false,address(this));vm.recordLogs();
        s.posm.permit(address(0xbeef),1,type(uint256).max,513,bytes("1271"));
        require(s.posm.getApproved(1)==address(0xbeef)&&s.posm.nonces(address(this),2)==2,"ERC721 permit");
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeWithSignature("permit(address,uint256,uint256,uint256,bytes)",address(0xbeef),uint256(1),type(uint256).max,uint256(513),bytes("1271")),0,false)));
        s.posm.permitForAll(address(this),address(0xabcd),true,type(uint256).max,514,bytes("1271"));s.posm.revokeNonce(515);
        require(s.posm.isApprovedForAll(address(this),address(0xabcd))&&s.posm.nonces(address(this),2)==14,"permit nonces");
        IAllowanceTransfer.PermitSingle memory single=IAllowanceTransfer.PermitSingle(IAllowanceTransfer.PermitDetails(address(a),123,type(uint48).max,0),target,type(uint256).max);
        require(s.posm.permit(address(this),single,hex"1271").length==0,"Permit2 single forwarding");
        IAllowanceTransfer.PermitDetails[] memory details=new IAllowanceTransfer.PermitDetails[](1);details[0]=IAllowanceTransfer.PermitDetails(address(b),456,type(uint48).max,0);
        require(s.posm.permitBatch(address(this),IAllowanceTransfer.PermitBatch(details,target,type(uint256).max),hex"1271").length==0,"Permit2 batch forwarding");
        (uint160 allowanceA,,uint48 nonceA)=permit.allowance(address(this),address(a),target);(uint160 allowanceB,,uint48 nonceB)=permit.allowance(address(this),address(b),target);
        require(allowanceA==123&&allowanceB==456&&nonceA==1&&nonceB==1,"real Permit2 state");
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeCall(s.posm.withdrawClaim,(s.key.currency0,uint256(0),address(1))),1,false)));
        trace=keccak256(abi.encode(trace,callDigest(target,abi.encodeCall(s.posm.unwindPosition,(uint256(1),uint128(0),uint128(0),bytes(""))),1,false)));
        return digest(s,abi.encode(trace,s.posm.getApproved(1),s.posm.nonces(address(this),2)));
    }
    function test_transferGuardsAndDomain() public {
        uint256 snap=vm.snapshotState();bytes32 expected=guards(false);require(vm.revertToState(snap));require(guards(true)==expected,"guard parity");
    }
    function guards(bool fePosition) internal returns(bytes32){
        System memory s=system(false,fePosition,false,500000);mint(s,10000,false,address(this));
        bytes32 domain=keccak256(abi.encode(keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),keccak256("Uniswap v4 Positions NFT"),block.chainid,address(s.posm)));
        require(s.posm.DOMAIN_SEPARATOR()==domain,"base domain preserved");
        bytes[3] memory calls=[abi.encodeWithSignature("transferFrom(address,address,uint256)",address(this),address(lp),uint256(1)),abi.encodeWithSignature("safeTransferFrom(address,address,uint256)",address(this),address(lp),uint256(1)),abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)",address(this),address(lp),uint256(1),bytes(""))];
        bytes32 trace;
        for(uint256 i;i<3;i++){(bool ok,bytes memory out)=address(s.posm).call(calls[i]);require(!ok&&bytes4(out)==PermissionedPositionManager.TransferDisabled.selector,"nontransferable");trace=keccak256(abi.encode(trace,out));}
        return trace;
    }
}
