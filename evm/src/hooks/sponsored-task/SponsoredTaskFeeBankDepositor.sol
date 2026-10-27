// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC3009Receive } from "./interfaces/IERC3009Receive.sol";
import { ISponsoredTaskFeeBank } from "./interfaces/ISponsoredTaskFeeBank.sol";

/// @title SponsoredTaskFeeBankDepositor
/// @notice rev030: deposits fee credit from a depositor's EIP-3009 authorization, so a relayer
///         can submit the deposit and pay its gas. It pulls the fee token from the depositor and
///         passes it to the existing fee bank with `depositFor(manager, amount)` in the same call.
/// @dev Stateless and ownerless: it holds no tokens and no allowance between calls. The manager
///      to credit is bound into the EIP-3009 nonce (`authorizationNonce`), so the depositor's
///      signature cannot be replayed to credit anyone else, and the token's own nonce check stops
///      a second use.
contract SponsoredTaskFeeBankDepositor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ISponsoredTaskFeeBank public immutable feeBank;
    IERC20 public immutable feeToken;

    error ZeroAddress();
    error InvalidContract(address account);
    error InvalidAmount();

    event CreditDepositedWithAuthorization(
        address indexed depositor, address indexed manager, uint256 amount, uint256 managerCreditAfter
    );

    constructor(ISponsoredTaskFeeBank feeBank_) {
        if (address(feeBank_) == address(0)) revert ZeroAddress();
        if (address(feeBank_).code.length == 0) revert InvalidContract(address(feeBank_));
        feeBank = feeBank_;
        feeToken = feeBank_.feeToken();
    }

    /// @notice The EIP-3009 nonce a depositor signs to credit `manager`, unique per `salt`.
    function authorizationNonce(address manager, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), manager, salt));
    }

    /// @notice Pulls `amount` from `depositor` with their authorization and credits `manager`.
    function depositWithAuthorization(
        address depositor,
        address manager,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 salt,
        bytes calldata signature
    ) external nonReentrant returns (uint256 managerCreditAfter) {
        if (depositor == address(0) || manager == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // The fee bank's `depositFor` pulls exactly `amount` from this contract and checks it
        // received exactly that, so an inexact pull here fails there; nothing stays behind.
        IERC3009Receive(address(feeToken))
            .receiveWithAuthorization(
                depositor, address(this), amount, validAfter, validBefore, authorizationNonce(manager, salt), signature
            );
        feeToken.forceApprove(address(feeBank), amount);
        managerCreditAfter = feeBank.depositFor(manager, amount);
        feeToken.forceApprove(address(feeBank), 0);
        emit CreditDepositedWithAuthorization(depositor, manager, amount, managerCreditAfter);
    }
}
