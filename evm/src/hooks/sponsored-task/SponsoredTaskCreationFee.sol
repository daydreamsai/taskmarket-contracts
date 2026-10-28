// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC3009Receive } from "./interfaces/IERC3009Receive.sol";

/// @title SponsoredTaskCreationFee
/// @notice The one-time vault creation fee a Sponsored Task factory takes from the vault creator.
/// @dev The fee exists to make mass-creating junk vaults cost something. It is taken inside the
///      vault-creation call, moves straight from the creator to the fee recipient, and is never
///      refunded. Creating tasks from a vault charges nothing.
///
///      The fee token, amount and recipient are fixed at deployment and nothing can change them, so
///      there is no fee admin key to custody or leak. A different fee or recipient takes a new
///      factory; vaults from this one keep working, since a vault does not depend on its factory.
abstract contract SponsoredTaskCreationFee {
    using SafeERC20 for IERC20;

    /// @notice Deployment parameters for the creation fee.
    struct CreationFeeConfig {
        IERC20 token;
        uint256 amount;
        address recipient;
    }

    /// @notice The token the fee is paid in.
    IERC20 public immutable feeToken;
    /// @notice The fee every vault creation pays, in `feeToken` base units.
    uint256 public immutable creationFee;
    /// @notice Where every vault creation's fee is paid.
    address public immutable creationFeeRecipient;

    error FeeTokenRequired();
    error FeeRecipientRequired();
    error FeeRecipientInvalid(address recipient);
    error FeeTransferAmountMismatch(uint256 expected, uint256 received);

    /// @notice Emitted once, at deployment, with the fee this factory charges for its lifetime.
    event CreationFeeUpdated(uint256 amount, address indexed recipient);
    event CreationFeePaid(address indexed vault, address indexed payer, address indexed recipient, uint256 amount);

    /// @dev A zero fee may use a zero recipient; a non-zero fee needs a recipient other than this
    ///      factory.
    constructor(CreationFeeConfig memory config) {
        if (address(config.token) == address(0) || address(config.token).code.length == 0) {
            revert FeeTokenRequired();
        }
        if (config.amount != 0 && config.recipient == address(0)) revert FeeRecipientRequired();
        if (config.recipient == address(this)) revert FeeRecipientInvalid(config.recipient);
        feeToken = config.token;
        creationFee = config.amount;
        creationFeeRecipient = config.recipient;
        emit CreationFeeUpdated(config.amount, config.recipient);
    }

    /// @dev Pulls the fee from `payer`, which must have approved this contract, straight to the
    ///      recipient.
    function _collectCreationFee(address vault, address payer) internal {
        uint256 amount = creationFee;
        if (amount == 0) return;
        address recipient = creationFeeRecipient;
        uint256 before = feeToken.balanceOf(recipient);
        feeToken.safeTransferFrom(payer, recipient, amount);
        _requireReceived(recipient, before, amount);
        emit CreationFeePaid(vault, payer, recipient, amount);
    }

    /// @dev Takes the fee with `payer`'s EIP-3009 authorization to this contract, then forwards
    ///      it to the recipient in the same call, so nothing stays here.
    function _collectCreationFeeWithAuthorization(
        address vault,
        address payer,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal {
        uint256 amount = creationFee;
        if (amount == 0) return;
        address recipient = creationFeeRecipient;
        uint256 heldBefore = feeToken.balanceOf(address(this));
        IERC3009Receive(address(feeToken))
            .receiveWithAuthorization(payer, address(this), amount, validAfter, validBefore, nonce, signature);
        _requireReceived(address(this), heldBefore, amount);
        uint256 before = feeToken.balanceOf(recipient);
        feeToken.safeTransfer(recipient, amount);
        _requireReceived(recipient, before, amount);
        emit CreationFeePaid(vault, payer, recipient, amount);
    }

    function _requireReceived(address account, uint256 before, uint256 amount) private view {
        uint256 afterBalance = feeToken.balanceOf(account);
        uint256 received = afterBalance >= before ? afterBalance - before : 0;
        if (received != amount) revert FeeTransferAmountMismatch(amount, received);
    }
}
