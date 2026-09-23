// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Currency, CurrencyLibrary} from "./reference/src/types/Currency.sol";
import {CustomRevert} from "./reference/src/libraries/CustomRevert.sol";
interface Vm {
    function readFile(string calldata) external view returns(string memory);
    function parseBytes(string calldata) external pure returns(bytes memory);
    function deal(address,uint256) external;
}
contract SolidityCurrencyHarness {
    function transfer(address currency,address to,uint256 amount) external { Currency.wrap(currency).transfer(to,amount); }
    function balanceOf(address currency,address owner) external view returns(uint256) { return Currency.wrap(currency).balanceOf(owner); }
    function balanceOfSelf(address currency) external view returns(uint256) { return Currency.wrap(currency).balanceOfSelf(); }
    function identity(uint256 id,address other) external pure returns(address,uint256,bool,bool,bool,bool,bool) {
        Currency a=CurrencyLibrary.fromId(id); Currency b=Currency.wrap(other);
        return (Currency.unwrap(a),a.toId(),a.isAddressZero(),a==b,a<b,a>b,a>=b);
    }
}
contract ResponseToken {
    bytes response;
    bool failure;
    bool writeOnBalance;
    bool returnOwner;
    uint256 public calls;
    address public lastTo;
    uint256 public lastAmount;
    function configure(bytes memory data,bool fail,bool writeBalance,bool ownerResult) external {
        response=data;failure=fail;writeOnBalance=writeBalance;returnOwner=ownerResult;
        calls=0;lastTo=address(0);lastAmount=0;
    }
    fallback() external {
        if(msg.sig==bytes4(keccak256("transfer(address,uint256)"))) {
            require(msg.data.length==68,"transfer calldata length");
            (address to,uint256 amount)=abi.decode(msg.data[4:],(address,uint256));
            calls++;lastTo=to;lastAmount=amount;
        } else {
            require(msg.sig==bytes4(keccak256("balanceOf(address)")),"wrong selector");
            require(msg.data.length==36,"balance calldata length");
            if(writeOnBalance) calls++;
            if(returnOwner) { address owner=abi.decode(msg.data[4:],(address)); assembly { mstore(0,owner) return(0,32) } }
        }
        bytes memory data=response;
        if(failure) { assembly { revert(add(data,32),mload(data)) } }
        assembly { return(add(data,32),mload(data)) }
    }
}
contract NativeRecipient {
    bytes response;
    bool failure;
    uint256 public calls;
    uint256 public received;
    function configure(bytes memory data,bool fail) external { response=data;failure=fail;calls=0;received=0; }
    fallback() external payable {
        require(msg.data.length==0,"native calldata");
        calls++;received+=msg.value;
        bytes memory data=response;
        if(failure) { assembly { revert(add(data,32),mload(data)) } }
        assembly { return(add(data,32),mload(data)) }
    }
}
contract CurrencyParityTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    SolidityCurrencyHarness sol;
    ResponseToken token;
    NativeRecipient recipient;
    function setUp() public {
        bytes memory code=vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address deployed; assembly { deployed:=create(0,add(code,32),mload(code)) }
        require(deployed.code.length>0,"Fe deploy");fe=deployed;
        sol=new SolidityCurrencyHarness();token=new ResponseToken();recipient=new NativeRecipient();
    }
    function compare(bytes memory data) internal returns(bool ok,bytes memory result) {
        (ok,result)=fe.call{gas:1000000}(data);
        (bool other,bytes memory expected)=address(sol).call{gas:1000000}(data);
        require(ok==other,"success mismatch");require(keccak256(result)==keccak256(expected),"return/revert mismatch");
    }
    function response(uint256 word,uint8 length) internal pure returns(bytes memory data) {
        data=new bytes(length);
        for(uint256 i;i<length;i++) data[i]=bytes1(uint8(i+11));
        if(length>=32) assembly { mstore(add(data,32),word) }
    }
    function testFuzz_identity(uint256 id,address other) public {
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.identity,(id,other)));
        require(ok,"identity");
        (address c,uint256 value,bool zero,bool eq,bool lt,bool gt,bool ge)=abi.decode(out,(address,uint256,bool,bool,bool,bool,bool));
        require(c==address(uint160(id)) && value==uint160(id) && zero==(uint160(id)==0),"identity model");
        require(eq==(c==other) && lt==(c<other) && gt==(c>other) && ge==(c>=other),"order model");
    }
    function testFuzz_erc20Transfer(address to,uint256 amount,uint256 word,uint8 length,bool failure) public {
        bytes memory data=response(word,length);token.configure(data,failure,false,false);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.transfer,(address(token),to,amount)));
        bool accepted=!failure && (length==0 || (length>=32 && word==1));
        require(ok==accepted,"transfer acceptance model");
        if(accepted) {
            require(token.calls()==2 && token.lastTo()==to && token.lastAmount()==amount,"transfer effects");
        } else {
            require(token.calls()==0,"failed transfer effects rolled back");
            require(keccak256(out)==keccak256(abi.encodeWithSelector(CustomRevert.WrappedError.selector,address(token),bytes4(0xa9059cbb),data,abi.encodePacked(CurrencyLibrary.ERC20TransferFailed.selector))),"ERC7751 wrapper");
        }
    }
    function testFuzz_tokenBalance(address owner,uint256 word,uint8 length,bool failure) public {
        bytes memory data=response(word,length);token.configure(data,failure,false,false);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.balanceOf,(address(token),owner)));
        require(ok==(!failure && length>=32),"balance acceptance");
        if(ok) require(abi.decode(out,(uint256))==word,"balance word");
        else require(keccak256(out)==keccak256(failure?data:bytes("")),"balance revert");
        compare(abi.encodeCall(sol.balanceOfSelf,(address(token))));
    }
    function testFuzz_nativeTransfer(uint128 amount,uint128 balance,uint8 length,bool failure) public {
        bytes memory data=response(7,length);recipient.configure(data,failure);
        vm.deal(fe,balance);vm.deal(address(sol),balance);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.transfer,(address(0),address(recipient),amount)));
        bool accepted=amount<=balance && !failure;
        require(ok==accepted,"native acceptance");
        require(fe.balance==(accepted?uint256(balance)-amount:balance) && address(sol).balance==fe.balance,"sender balances");
        require(recipient.calls()==(accepted?2:0) && recipient.received()==(accepted?uint256(amount)*2:0),"recipient effects");
        if(!accepted) {
            bytes memory reason=amount>balance?bytes(""):data;
            require(keccak256(out)==keccak256(abi.encodeWithSelector(CustomRevert.WrappedError.selector,address(recipient),bytes4(0),reason,abi.encodePacked(CurrencyLibrary.NativeTransferFailed.selector))),"native wrapper");
        }
    }
    function testFuzz_nativeBalances(uint128 balance,uint128 ownerBalance) public {
        address owner=address(0x1234567890);vm.deal(owner,ownerBalance);vm.deal(fe,balance);vm.deal(address(sol),balance);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.balanceOf,(address(0),owner)));
        require(ok && abi.decode(out,(uint256))==ownerBalance,"native owner balance");
        (ok,out)=compare(abi.encodeCall(sol.balanceOfSelf,(address(0))));
        require(ok && abi.decode(out,(uint256))==balance,"native self balance");
    }
    function test_transferReturnBoundaries() public {
        uint8[9] memory lengths=[uint8(0),1,4,31,32,33,63,64,255];
        for(uint256 i;i<lengths.length;i++) {
            testFuzz_erc20Transfer(address(0x1234567890),99,1,lengths[i],false);
            testFuzz_erc20Transfer(address(0),0,0,lengths[i],false);
            testFuzz_erc20Transfer(address(0),0,2,lengths[i],true);
            testFuzz_tokenBalance(address(0),type(uint256).max,lengths[i],false);
        }
    }
    function test_codelessAndStaticBalance() public {
        address empty=address(0x1234567890);
        (bool ok,)=compare(abi.encodeCall(sol.transfer,(empty,address(0),uint256(99))));
        require(ok,"v4 accepts empty codeless transfer");
        (ok,)=compare(abi.encodeCall(sol.balanceOf,(empty,address(0))));require(!ok,"codeless balance rejected");
        token.configure(abi.encode(uint256(1)),false,true,false);
        (ok,)=compare(abi.encodeCall(sol.balanceOf,(address(token),address(0))));require(!ok && token.calls()==0,"STATICCALL must reject mutation");
        token.configure(bytes(""),false,false,true);
        bytes memory ignored;
        (ok,ignored)=compare(abi.encodeCall(sol.balanceOf,(address(token),address(0xdead))));
        require(ok && abi.decode(ignored,(uint256))==0xdead,"owner calldata");
        (ok,ignored)=fe.call(abi.encodeCall(sol.balanceOfSelf,(address(token))));
        require(ok && abi.decode(ignored,(uint256))==uint160(fe),"Fe self address");
        require(sol.balanceOfSelf(address(token))==uint160(address(sol)),"Solidity self address");
    }
    function test_balanceEntrypointsAllowStaticcall() public {
        token.configure(abi.encode(uint256(17)),false,false,false);
        (bool ok,bytes memory out)=fe.staticcall(abi.encodeCall(sol.balanceOf,(address(token),address(0))));
        require(ok && abi.decode(out,(uint256))==17,"token static balance");
        (ok,out)=fe.staticcall(abi.encodeCall(sol.balanceOfSelf,(address(token))));
        require(ok && abi.decode(out,(uint256))==17,"token static self");
        vm.deal(fe,19);
        (ok,out)=fe.staticcall(abi.encodeCall(sol.balanceOfSelf,(address(0))));
        require(ok && abi.decode(out,(uint256))==19,"native static self");
    }
    function test_largeErrorPayload() public {
        bytes memory data=new bytes(4097);for(uint256 i;i<data.length;i++) data[i]=bytes1(uint8(i));
        token.configure(data,true,false,false);
        (bool ok,bytes memory out)=compare(abi.encodeCall(sol.transfer,(address(token),address(1),1)));
        require(!ok && keccak256(out)==keccak256(abi.encodeWithSelector(CustomRevert.WrappedError.selector,address(token),bytes4(0xa9059cbb),data,abi.encodePacked(CurrencyLibrary.ERC20TransferFailed.selector))),"full long error");
    }
}
