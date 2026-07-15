// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockUSDC } from "../src/mocks/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;

    uint256 internal constant PAYER_KEY = 0xA11CE;
    address internal payer;
    address internal payee = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        payer = vm.addr(PAYER_KEY);
        usdc.mint(payer, 1_000e6);
        vm.warp(1_000_000);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("USD Coin")),
                keccak256(bytes("2")),
                block.chainid,
                address(usdc)
            )
        );
    }

    function _signAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_transferWithAuthorization() public {
        bytes32 nonce = bytes32(uint256(1));
        bytes memory sig = _signAuthorization(
            usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payer,
            payee,
            100e6,
            block.timestamp - 1,
            block.timestamp + 300,
            nonce
        );

        usdc.transferWithAuthorization(payer, payee, 100e6, block.timestamp - 1, block.timestamp + 300, nonce, sig);

        assertEq(usdc.balanceOf(payee), 100e6);
        assertEq(usdc.balanceOf(payer), 900e6);
        assertTrue(usdc.authorizationState(payer, nonce));
    }

    function test_transferWithAuthorization_vrsOverload() public {
        bytes32 nonce = bytes32(uint256(2));
        bytes memory sig = _signAuthorization(
            usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payer,
            payee,
            50e6,
            block.timestamp - 1,
            block.timestamp + 300,
            nonce
        );
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(sig);

        usdc.transferWithAuthorization(payer, payee, 50e6, block.timestamp - 1, block.timestamp + 300, nonce, v, r, s);

        assertEq(usdc.balanceOf(payee), 50e6);
    }

    function test_transferWithAuthorization_replayReverts() public {
        bytes32 nonce = bytes32(uint256(3));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 300;
        bytes memory sig = _signAuthorization(
            usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), payer, payee, 10e6, validAfter, validBefore, nonce
        );

        usdc.transferWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, sig);

        vm.expectRevert(MockUSDC.AuthorizationAlreadyUsed.selector);
        usdc.transferWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, sig);
    }

    function test_transferWithAuthorization_expiredReverts() public {
        bytes32 nonce = bytes32(uint256(4));
        uint256 validAfter = block.timestamp - 100;
        uint256 validBefore = block.timestamp - 1;
        bytes memory sig = _signAuthorization(
            usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), payer, payee, 10e6, validAfter, validBefore, nonce
        );

        vm.expectRevert(MockUSDC.AuthorizationExpired.selector);
        usdc.transferWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, sig);
    }

    function test_transferWithAuthorization_wrongSignerReverts() public {
        bytes32 nonce = bytes32(uint256(5));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 300;
        bytes32 structHash = keccak256(
            abi.encode(
                usdc.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), payer, payee, uint256(10e6), validAfter, validBefore, nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);

        vm.expectRevert(MockUSDC.InvalidSignature.selector);
        usdc.transferWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    function test_receiveWithAuthorization_requiresPayeeCaller() public {
        bytes32 nonce = bytes32(uint256(6));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 300;
        bytes memory sig = _signAuthorization(
            usdc.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), payer, payee, 10e6, validAfter, validBefore, nonce
        );

        vm.expectRevert(MockUSDC.CallerMustBePayee.selector);
        usdc.receiveWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, sig);

        vm.prank(payee);
        usdc.receiveWithAuthorization(payer, payee, 10e6, validAfter, validBefore, nonce, sig);
        assertEq(usdc.balanceOf(payee), 10e6);
    }

    function _splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "bad sig length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }
}
