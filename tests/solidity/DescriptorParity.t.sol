// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Descriptor} from "./periphery/src/libraries/Descriptor.sol";

interface Vm {
    function readFile(string calldata) external view returns (string memory);
    function parseBytes(string calldata) external pure returns (bytes memory);
}
contract DescriptorReference {
    // A struct parameter keeps solc 0.8.26's unoptimized ABI wrapper below
    // its stack limit. The reference receives the original struct directly;
    // only the Fe test adapter needs the equivalent flat calldata encoding.
    function render(bool image, Descriptor.ConstructTokenURIParams memory p) external pure returns (string memory) {
        return image ? Descriptor.generateSVGImage(p) : Descriptor.constructTokenURI(p);
    }
    function circle(uint256 currency, uint256 offset, uint256 id) external pure returns (uint256) {
        return Descriptor.getCircleCoord(currency, offset, id);
    }
}
contract DescriptorParityTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address fe;
    DescriptorReference sol;
    function setUp() public {
        bytes memory code = vm.parseBytes(vm.readFile("fe-bytecode.txt"));
        address a;
        assembly ("memory-safe") { a := create(0, add(code, 32), mload(code)) }
        require(a.code.length > 0, "Fe deployment");
        fe = a;
        sol = new DescriptorReference();
    }
    function compare(bytes memory data, bool mustSucceed) internal view {
        compare(data, data, mustSucceed);
    }
    function compare(bytes memory data, bytes memory referenceData, bool mustSucceed) internal view {
        (bool a, bytes memory x) = fe.staticcall(data);
        (bool b, bytes memory y) = address(sol).staticcall(referenceData);
        require(!mustSucceed || b, "reference must succeed");
        require(a == b, "descriptor status");
        require(keccak256(x) == keccak256(y), "descriptor bytes");
    }
    function render(bool image, Descriptor.ConstructTokenURIParams memory p, bool mustSucceed) internal view {
        bytes memory fields = abi.encode(p);
        // Replace the outer tuple offset with the flat ABI's image flag, and
        // rebase the two dynamic string offsets past that extra flag word.
        assembly ("memory-safe") {
            mstore(add(fields, 32), image)
            mstore(add(fields, 160), add(mload(add(fields, 160)), 32))
            mstore(add(fields, 192), add(mload(add(fields, 192)), 32))
        }
        bytes4 selector = bytes4(keccak256("render(bool,uint256,address,address,string,string,uint8,uint8,bool,int24,int24,int24,int24,uint24,address,address)"));
        compare(bytes.concat(selector, fields), abi.encodeCall(sol.render, (image, p)), mustSucceed);
    }
    function defaults() internal pure returns (Descriptor.ConstructTokenURIParams memory p) {
        p.tokenId = 1;
        p.quoteCurrency = address(bytes20(hex"1234567890abcdef1234567890abcdef12345678"));
        p.baseCurrency = address(bytes20(hex"9876543210abcdef9876543210abcdef98765432"));
        p.quoteCurrencySymbol = "USDC";
        p.baseCurrencySymbol = "WETH";
        p.quoteCurrencyDecimals = 6;
        p.baseCurrencyDecimals = 18;
        p.tickLower = -120;
        p.tickUpper = 120;
        p.tickSpacing = 60;
        p.fee = 3000;
        p.poolManager = address(0x1234);
    }
    function testFuzz_render(uint64 id, address quote, address base, address hooks, int24 tick,
        uint24 fee, bool flip, string memory quoteSymbol, string memory baseSymbol) public view
    {
        Descriptor.ConstructTokenURIParams memory p = defaults();
        p.tokenId = id; p.quoteCurrency = quote; p.baseCurrency = base; p.hooks = hooks;
        p.tickCurrent = tick; p.fee = fee; p.flipRatio = flip;
        p.quoteCurrencySymbol = quoteSymbol; p.baseCurrencySymbol = baseSymbol;
        render(true, p, id != 0);
        render(false, p, id != 0 && bytes(quoteSymbol).length <= 255 && bytes(baseSymbol).length <= 255);
    }
    function testFuzz_prices(int24 lower, int24 upper, uint16 spacing, uint8 decimals, bool flip) public view {
        Descriptor.ConstructTokenURIParams memory p = defaults();
        p.tickLower = int24(int256(lower) % 887273);
        p.tickUpper = int24(int256(upper) % 887273);
        if (p.tickLower > p.tickUpper) (p.tickLower, p.tickUpper) = (p.tickUpper, p.tickLower);
        p.tickSpacing = int24(uint24(spacing) % 32767 + 1);
        p.baseCurrencyDecimals = decimals % 31;
        p.quoteCurrencyDecimals = p.baseCurrencyDecimals;
        p.flipRatio = flip;
        render(false, p, true);
    }
    function testFuzz_arbitrary(Descriptor.ConstructTokenURIParams memory p) public view {
        render(true, p, false);
        render(false, p, false);
    }
    function testFuzz_circle(uint256 currency, uint256 offset, uint256 id) public view {
        compare(abi.encodeCall(sol.circle, (currency, offset, id)), false);
    }
    function test_boundaries() public view {
        Descriptor.ConstructTokenURIParams memory p = defaults();
        for (uint256 i; i < 4; ++i) {
            p.quoteCurrency = i & 1 == 0 ? address(0) : address(1);
            p.baseCurrency = i & 2 == 0 ? address(0) : address(2);
            p.hooks = i == 0 ? address(0) : address(0x1234);
            p.quoteCurrencySymbol = string(hex"220c0a0d095c");
            p.baseCurrencySymbol = unicode"ETH €";
            render(false, p, true);
        }
        p = defaults();
        int24[5] memory ticks = [int24(-121), -120, 0, 120, 121];
        for (uint256 i; i < ticks.length; ++i) { p.tickCurrent = ticks[i]; render(false, p, true); }
        p.tickLower = -887272; p.tickUpper = 887272; p.tickSpacing = 1;
        render(false, p, true); p.flipRatio = true; render(false, p, true);
        p = defaults(); p.tokenId = 0;
        (bool ok, bytes memory reason) = address(sol).staticcall(abi.encodeCall(sol.render, (true, p)));
        require(!ok && reason.length == 0, "reference zero-id BitMath rejection");
        render(true, p, false); render(false, p, false);
        p = defaults(); p.tokenId = type(uint256).max;
        render(true, p, false); render(false, p, false);
        p = defaults(); p.tickSpacing = 0;
        render(true, p, false); render(false, p, false);
        p = defaults(); p.quoteCurrencySymbol = string(new bytes(256));
        render(false, p, false);
    }
}
