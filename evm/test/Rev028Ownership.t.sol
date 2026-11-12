// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { RewardVault } from "../src/hooks/RewardVault.sol";
import { TaskTokenRewardHookV2 } from "../src/hooks/TaskTokenRewardHookV2.sol";
import { SponsoredTaskHookV2 } from "../src/hooks/sponsored-task/SponsoredTaskHookV2.sol";
import { ISponsoredTaskRegistry } from "../src/hooks/sponsored-task/interfaces/ISponsoredTaskRegistry.sol";
import { RemoteSponsoredTaskHookV2 } from "../src/hooks/sponsored-task/RemoteSponsoredTaskHookV2.sol";
import { SponsoredTaskRegistry } from "../src/hooks/sponsored-task/SponsoredTaskRegistry.sol";

/// @dev The three UUPS V2 hooks hand upgrade authority over in two steps and cannot renounce it.
contract Rev028OwnershipTest is Test {
    address private constant OWNER = address(0x0A11);
    address private constant NEXT = address(0x0B0B);
    address private constant MISTAKE = address(0xDEAD);
    address private constant DIAMOND = address(0xD1A);

    address[3] private hooks;

    function setUp() public {
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6, address(this));
        SponsoredTaskRegistry registry = new SponsoredTaskRegistry(address(this));

        bytes memory rewardInit = abi.encodeCall(
            TaskTokenRewardHookV2.initialize,
            (
                address(new RewardVault(address(0x3), OWNER)),
                address(0x2),
                DIAMOND,
                18,
                1e18,
                0,
                address(0x3),
                8000,
                address(0x4),
                OWNER
            )
        );
        hooks[0] = address(new ERC1967Proxy(address(new TaskTokenRewardHookV2()), rewardInit));
        address sponsoredImpl =
            address(new SponsoredTaskHookV2(DIAMOND, usdc, ISponsoredTaskRegistry(address(registry))));
        hooks[1] = address(new ERC1967Proxy(sponsoredImpl, abi.encodeCall(SponsoredTaskHookV2.initialize, (OWNER))));
        address implV2 = address(new RemoteSponsoredTaskHookV2(DIAMOND));
        hooks[2] = address(new ERC1967Proxy(implV2, abi.encodeCall(RemoteSponsoredTaskHookV2.initialize, (OWNER))));
    }

    function test_TransferNeedsAcceptanceAndAWrongAddressCanBeCorrected() public {
        for (uint256 i; i < hooks.length; ++i) {
            Ownable2Step h = Ownable2Step(hooks[i]);

            // A transfer to a wrong address does not move upgrade authority.
            vm.prank(OWNER);
            h.transferOwnership(MISTAKE);
            assertEq(h.owner(), OWNER);
            assertEq(h.pendingOwner(), MISTAKE);

            // The owner can still upgrade, so the mistake is recoverable.
            vm.prank(OWNER);
            h.transferOwnership(NEXT);

            vm.prank(MISTAKE);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MISTAKE));
            h.acceptOwnership();

            vm.prank(NEXT);
            h.acceptOwnership();
            assertEq(h.owner(), NEXT);
            assertEq(h.pendingOwner(), address(0));
        }
    }

    function test_RenounceIsDisabled() public {
        for (uint256 i; i < hooks.length; ++i) {
            vm.prank(OWNER);
            (bool ok, bytes memory ret) = hooks[i].call(abi.encodeWithSignature("renounceOwnership()"));
            assertFalse(ok);
            assertEq(bytes4(ret), bytes4(keccak256("OwnershipRenunciationDisabled()")));
            assertEq(Ownable(hooks[i]).owner(), OWNER);
        }
    }
}
