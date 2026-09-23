// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
// Copy beside MulticallParity.t.sol in a built artifact to investigate the
// eager owned-array decoder versus Solidity's lazy calldata element access.
import {MulticallParityTest} from "./MulticallParity.t.sol";
contract MulticallDecoderOrderTest is MulticallParityTest {
    function test_decoderOrder() public {
        bytes[] memory calls=new bytes[](2);
        calls[0]=abi.encodeWithSignature("fail(bytes)",bytes("first call failed"));
        calls[1]=abi.encodeWithSignature("echo(bytes)",bytes("second"));
        bytes memory data=abi.encodeWithSignature("multicall(bytes[])",calls);
        // Second element's offset is at calldata byte 100. The first call
        // reverts, so Solidity never reads this deliberately invalid offset.
        assembly {mstore(add(data,132),0xffff)}
        compare(data,0);
    }
}
