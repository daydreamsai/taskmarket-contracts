// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Initializable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibAppStorage, AppStorage } from "../libraries/LibAppStorage.sol";
import { LibTaskMarket } from "../libraries/LibTaskMarket.sol";
import { ITMPCore } from "../interfaces/ITMPCore.sol";
import { ITMPFees } from "../interfaces/ITMPFees.sol";
import { ITMPReputation } from "../interfaces/ITMPReputation.sol";

/// @title AdminFacet — owner-only admin operations and proxy initialization
/// @notice Handles initialization, pause/unpause, fee settings, forwarder registry,
///         and 2-step ownership transfer (delegated to LibDiamond).
contract AdminFacet is Initializable {
    event Paused(address account);
    event Unpaused(address account);

    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    /// @notice Initialize the Diamond proxy.
    ///         Called via delegatecall during the initial diamondCut.
    ///         Ownership is set by the Diamond constructor before this runs.
    /// @param _usdcToken    USDC token address on Base
    /// @param _feeRecipient Address to receive platform fees
    /// @param _defaultFeeBps Default platform fee in basis points (500 = 5%)
    function initialize(address _usdcToken, address _feeRecipient, uint16 _defaultFeeBps) external initializer {
        AppStorage storage s = LibAppStorage.appStorage();
        if (_usdcToken == address(0)) revert ITMPCore.InvalidUSDCToken();
        if (_feeRecipient == address(0)) revert ITMPCore.InvalidFeeRecipient();
        if (_defaultFeeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
        s.usdcToken = IERC20(_usdcToken);
        s.feeRecipient = _feeRecipient;
        s.defaultFeeBps = _defaultFeeBps;
        s.reentrancyStatus = LibTaskMarket.NOT_ENTERED;
        // Rev011: a fresh deploy already includes today's full steady-state selector set
        // (FacetSelectors.sol), so it starts at the current revision rather than 0.
        s.diamondVersion = 11;
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    /// @notice Returns true if the contract is currently paused.
    function paused() external view returns (bool) {
        return LibAppStorage.appStorage().paused;
    }

    /// @notice Halt all state-mutating operations (owner only).
    function pause() external onlyOwner {
        AppStorage storage s = LibAppStorage.appStorage();
        s.paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Restore normal operation (owner only).
    function unpause() external onlyOwner {
        AppStorage storage s = LibAppStorage.appStorage();
        s.paused = false;
        emit Unpaused(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Ownership (2-step via LibDiamond)
    // -------------------------------------------------------------------------

    /// @notice Initiate ownership transfer to newOwner (owner only).
    ///         newOwner must call acceptOwnership() to complete.
    function transferOwnership(address newOwner) external onlyOwner {
        LibDiamond.transferOwnership(newOwner);
    }

    /// @notice Complete ownership transfer. Must be called by pendingOwner.
    function acceptOwnership() external {
        LibDiamond.acceptOwnership();
    }

    /// @notice Returns the current contract owner.
    function owner() external view returns (address) {
        return LibDiamond.diamondStorage().contractOwner;
    }

    /// @notice Returns the pending owner awaiting acceptOwnership().
    function pendingOwner() external view returns (address) {
        return LibDiamond.diamondStorage().pendingOwner;
    }

    // -------------------------------------------------------------------------
    // Forwarder registry
    // -------------------------------------------------------------------------

    /// @notice Add a trusted PGTR forwarder (owner only).
    function addForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ITMPCore.InvalidForwarderAddress();
        AppStorage storage s = LibAppStorage.appStorage();
        s.trustedForwarders[forwarder] = true;
        emit ITMPCore.ForwarderUpdated(forwarder, true);
    }

    /// @notice Remove a trusted PGTR forwarder (owner only).
    function removeForwarder(address forwarder) external onlyOwner {
        AppStorage storage s = LibAppStorage.appStorage();
        s.trustedForwarders[forwarder] = false;
        emit ITMPCore.ForwarderUpdated(forwarder, false);
    }

    /// @notice Returns true if addr is a trusted PGTR forwarder (ERC-8194).
    function isTrustedForwarder(address addr) external view returns (bool) {
        return LibAppStorage.appStorage().trustedForwarders[addr];
    }

    // -------------------------------------------------------------------------
    // Fee settings
    // -------------------------------------------------------------------------

    /// @notice Set default platform fee (owner only).
    function setDefaultFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > 10000) revert ITMPCore.FeeBpsTooHigh();
        AppStorage storage s = LibAppStorage.appStorage();
        s.defaultFeeBps = feeBps;
        emit ITMPFees.FeesUpdated(feeBps);
    }

    /// @notice Set fee recipient (owner only).
    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ITMPCore.InvalidRecipient();
        AppStorage storage s = LibAppStorage.appStorage();
        s.feeRecipient = recipient;
        emit ITMPFees.FeeRecipientUpdated(recipient);
    }

    // -------------------------------------------------------------------------
    // Reputation registry
    // -------------------------------------------------------------------------

    /// @notice Set the ERC-8004 reputation registry address (owner only).
    function setReputationRegistry(address registry) external onlyOwner {
        LibAppStorage.appStorage().reputationRegistry = registry;
        emit ITMPReputation.ReputationRegistryUpdated(registry);
    }

    // -------------------------------------------------------------------------
    // Default hooks (Rev008)
    // -------------------------------------------------------------------------

    /// @notice Replace the protocol default hook list (owner only).
    ///         These hooks are prepended to every new task's hook list at createTask().
    ///         Does not affect tasks already created.
    ///         Maximum 8 default hooks to bound hook dispatch gas cost.
    function setDefaultHooks(address[] calldata hooks) external onlyOwner {
        if (hooks.length > 8) revert ITMPCore.TooManyHooks();
        AppStorage storage s = LibAppStorage.appStorage();
        delete s.defaultHooks;
        for (uint256 i; i < hooks.length; i++) {
            if (hooks[i] == address(0)) revert ITMPCore.InvalidHookAddress();
            if (hooks[i].code.length == 0) revert ITMPCore.InvalidHookAddress();
            for (uint256 j; j < i; j++) {
                if (hooks[j] == hooks[i]) revert ITMPCore.DuplicateHookAddress();
            }
            s.defaultHooks.push(hooks[i]);
        }
        emit ITMPCore.DefaultHooksSet(hooks);
    }

    /// @notice Return the current protocol default hook list.
    function getDefaultHooks() external view returns (address[] memory) {
        return LibAppStorage.appStorage().defaultHooks;
    }

    // -------------------------------------------------------------------------
    // Diamond version (Rev011)
    // -------------------------------------------------------------------------

    /// @notice Return the diamond's current upgrade-step version.
    ///         Zero on any diamond deployed before version tracking existed.
    function diamondVersion() external view returns (uint256) {
        return LibAppStorage.appStorage().diamondVersion;
    }

    /// @notice Set the diamond's upgrade-step version (owner only).
    ///         Called by upgrade step scripts after applying their delta -- never by end users.
    ///         Monotonic: reverts if newVersion would move the counter backwards, so a step
    ///         cannot be applied out of order. Re-applying the same target version (e.g. running
    ///         `make upgrade` again against an already-current diamond) is a no-op, not an error.
    function setDiamondVersion(uint256 newVersion) external onlyOwner {
        AppStorage storage s = LibAppStorage.appStorage();
        if (newVersion < s.diamondVersion) revert ITMPCore.DiamondVersionNotIncreasing();
        s.diamondVersion = newVersion;
    }
}
