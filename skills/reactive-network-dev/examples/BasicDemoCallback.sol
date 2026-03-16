// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import '../../../lib/reactive-lib/src/abstract-base/AbstractCallback.sol';

/// @notice Simplest possible Callback Contract.
/// Receives a "Ping" callback from the RC and emits a "Pong" event.
/// Deploy on the destination chain (e.g., Sepolia).
contract BasicDemoCallback is AbstractCallback {

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when the RC sends a Ping callback. RC subscribes to this.
    event Ping(address indexed sender, uint256 value);

    /// @notice Emitted in response to a Ping callback from the RC.
    event Pong(address indexed rvm_id, uint256 value);

    // ── State ─────────────────────────────────────────────────────────────────

    address public immutable owner;
    uint256 public pongCount;

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param _owner           Owner of this contract.
    /// @param _callbackSender  RVM ID — the EOA address used to deploy the RC.
    constructor(address _owner, address _callbackSender)
        payable AbstractCallback(_callbackSender)
    {
        owner = _owner;
    }

    // ── User-callable: emit a Ping ────────────────────────────────────────────

    /// @notice Anyone can call this to emit a Ping event.
    /// The RC is subscribed to this event and will respond with a pong() callback.
    function ping(uint256 value) external {
        emit Ping(msg.sender, value);
    }

    // ── RC callback entry point ───────────────────────────────────────────────

    /// @notice Called by the Reactive Network when the RC reacts to a Ping event.
    /// @param sender  Injected by RN — the RVM ID of the RC (verified by authorizedSenderOnly).
    /// @param value   The value from the original Ping event, echoed back.
    function pong(address sender, uint256 value) external authorizedSenderOnly {
        pongCount++;
        emit Pong(sender, value);
    }
}
