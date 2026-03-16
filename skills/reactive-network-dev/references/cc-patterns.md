# CC Contract Patterns Reference

## AbstractCallback Inheritance

```solidity
import "reactive-lib/src/abstract-base/AbstractCallback.sol";

contract MyCallback is AbstractCallback {
    constructor(
        address _owner,
        address _callbackSender   // Callback Proxy address for this destination chain
    ) payable AbstractCallback(_callbackSender) {
        owner = _owner;
    }
}
```

**Important:** `_callbackSender` is the **Callback Proxy address** for the specific chain where the CC is deployed. Each chain has its own proxy:
- Sepolia: `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`
- Base Sepolia: `0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`
- Base Mainnet: `0x0D3E76De6bC44309083cAAFdB49A088B8a250947`
- Reactive (mainnet & testnet): `0x0000000000000000000000000000000000fffFfF`
- See `references/architecture.md` for the full table.

This is NOT your wallet address or the RC's address. It is a protocol-level proxy per chain.

`AbstractCallback` provides the `authorizedSenderOnly` modifier:
```solidity
modifier authorizedSenderOnly() {
    // Checks: msg.sender == _callbackSender (the chain's Callback Proxy)
    _;
}
```

---

## Entry Point Pattern

The main function called by the RC via a `Callback` event. Always mark with `authorizedSenderOnly`.

**Critical:** The first parameter MUST always be `address` — the RVM ID sender slot. This is an extra parameter prepended to any business params. If your function needs `(uint256 id, string msg)`, the signature is `fn(address sender, uint256 id, string msg)`. The RC passes `address(0)` for this slot and the RN replaces it with the actual RVM ID.

```solidity
// The first parameter is always `address sender` — it receives the RVM ID injected by RN.
// This is NOT a business parameter. It is always present, even if unused.
// Mark it with /* */ to suppress "unused parameter" warnings.
function doWork(address /* sender */) external authorizedSenderOnly {
    uint256 executed = 0;
    uint256 checked = 0;

    for (uint256 i = 0; i < items.length; i++) {
        Item storage item = items[i];
        if (item.status != Status.Active) continue;
        checked++;

        try this._executeItem(i) returns (bool wasExecuted) {
            if (wasExecuted) executed++;
        } catch {
            // Per-item failure must not abort the entire cycle
            emit ItemCheckFailed(i, "Unexpected error");
        }
    }

    // ALWAYS emit cycle completion — even if nothing executed
    // The RC subscribes to this event to reset any processing state
    emit CycleCompleted(block.timestamp, checked, executed);
}
```

---

## try-catch Internal Execution Pattern

Use `external` functions + `try this._fn()` for per-item isolation. This ensures one item's failure doesn't revert the entire transaction.

```solidity
// External function — callable only by address(this) (enforced by require)
function _executeItem(uint256 itemId) external returns (bool) {
    require(msg.sender == address(this), "Internal function");

    Item storage item = items[itemId];

    // Check cooldown
    if (
        item.lastAttempt > 0 &&
        block.timestamp < item.lastAttempt + RETRY_COOLDOWN
    ) {
        return false;
    }

    item.lastAttempt = block.timestamp;

    bool success = _performAction(item);

    if (success) {
        item.consecutiveFailures = 0;
        item.successCount++;
        emit ItemExecuted(itemId, /* result data */);
    } else {
        item.consecutiveFailures++;
        if (item.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
            // Auto-cancel: emit event so RC unsubscribes from cron
            item.status = Status.Cancelled;
            emit ItemCancelled(itemId);
            emit ItemCheckFailed(itemId, "Auto-cancelled: max consecutive failures");
        }
    }

    return success;
}
```

**Why `external` and not `internal`?**
Solidity's `try/catch` only works on external function calls. The pattern `try this._fn()` makes an external call to `address(this)`, which can be caught by the caller.

---

## Lifecycle Events RC Subscribes To

Define these events in the CC. The RC's constructor subscribes to them. They form the feedback loop.

```solidity
// ── Emitted by owner actions (user triggers) ─────────────────────────────
event ItemConfigured(
    uint256 indexed itemId,    // topic_1 — RC uses for filtering
    uint8   itemType,          // non-indexed (in data)
    uint256 threshold,         // non-indexed
    uint256 target,            // non-indexed
    address assetA,            // non-indexed
    address assetB             // non-indexed
);

event ItemCancelled(uint256 indexed itemId);   // topic_1
event ItemPaused(uint256 indexed itemId);      // topic_1
event ItemResumed(uint256 indexed itemId);     // topic_1

// ── Emitted by RC-triggered execution ────────────────────────────────────
event ItemExecuted(
    uint256 indexed itemId,
    string  method,
    address asset,
    uint256 amount,
    uint256 prevValue,
    uint256 newValue
);

// ── Emitted at end of every cycle — ALWAYS, even if nothing executed ─────
event CycleCompleted(
    uint256 timestamp,
    uint256 totalChecked,
    uint256 executionsPerformed
);
```

**RC subscription setup in constructor:**
```solidity
if (!vm) {
    service.subscribe(destChainId, callbackContract, ITEM_CONFIGURED_TOPIC_0, ...);
    service.subscribe(destChainId, callbackContract, ITEM_CANCELLED_TOPIC_0, ...);
    service.subscribe(destChainId, callbackContract, ITEM_EXECUTED_TOPIC_0, ...);
    service.subscribe(destChainId, callbackContract, ITEM_PAUSED_TOPIC_0, ...);
    service.subscribe(destChainId, callbackContract, ITEM_RESUMED_TOPIC_0, ...);
    service.subscribe(destChainId, callbackContract, CYCLE_COMPLETED_TOPIC_0, ...);
    // Cron NOT here — lazy subscription in callbackOnly
}
```

---

## Consecutive Failure + Auto-Cancel Pattern

Track failures per item. After `MAX_CONSECUTIVE_FAILURES`, cancel the item and emit a cancel event. The RC listens for the cancel event and unsubscribes from cron when `activeCount` reaches zero.

```solidity
uint8 private constant MAX_CONSECUTIVE_FAILURES = 5;

// In _executeItem:
if (!success) {
    item.consecutiveFailures++;
    if (item.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        item.status = Status.Cancelled;
        emit ItemCancelled(item.id); // ← RC intercepts this, decrements activeCount
    }
}
if (success) {
    item.consecutiveFailures = 0; // Reset on success
}
```

**Why this matters:** If the CC's underlying action consistently fails (e.g., insufficient funds, oracle failure), the cron keeps firing with no useful work. Auto-cancel stops the waste and signals the RC to unsubscribe.

---

## Retry Cooldown Pattern

Prevent hammering failed items on every cron tick.

```solidity
uint256 private constant RETRY_COOLDOWN = 30; // seconds

struct Item {
    // ...
    uint256 lastExecutionAttempt;
    uint8   consecutiveFailures;
}

// In _executeItem:
if (
    item.lastExecutionAttempt > 0 &&
    block.timestamp < item.lastExecutionAttempt + RETRY_COOLDOWN
) {
    return false; // Too soon since last attempt
}
item.lastExecutionAttempt = block.timestamp;
```

---

## CycleCompleted Guarantee

**Always** emit `CycleCompleted` (or equivalent) at the end of the main entry point, regardless of whether any executions occurred.

```solidity
function doWork(address /* sender */) external authorizedSenderOnly {
    uint256 executed = 0;
    uint256 checked = 0;

    for (...) {
        // ... per-item logic ...
    }

    // ALWAYS emit — never skip this
    emit CycleCompleted(block.timestamp, checked, executed);
}
```

**Why:** The RC may track a "processing in progress" flag (or similar observability state) by subscribing to `CycleCompleted`. If the event is sometimes not emitted, the RC's state can get stuck. Emitting it unconditionally is a safety guarantee.

In the Aave Protection system, `ProtectionCycleCompleted` is emitted at the end of every `checkAndProtectPositions` call. The RC subscribes to it and emits a local `ProtectionCycleCompleted` event on its side for observability.

---

## Full CC Skeleton

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "reactive-lib/src/abstract-base/AbstractCallback.sol";

contract MyCallback is AbstractCallback {

    enum Status { Active, Paused, Cancelled }

    struct Item {
        uint256 id;
        Status  status;
        uint256 threshold;
        uint256 lastAttempt;
        uint8   consecutiveFailures;
    }

    event ItemConfigured(uint256 indexed id, uint256 threshold);
    event ItemExecuted(uint256 indexed id, uint256 result);
    event ItemCancelled(uint256 indexed id);
    event ItemPaused(uint256 indexed id);
    event ItemResumed(uint256 indexed id);
    event ItemCheckFailed(uint256 indexed id, string reason);
    event CycleCompleted(uint256 timestamp, uint256 checked, uint256 executed);

    address public immutable owner;

    Item[] public items;
    uint256 public nextId;

    uint8   private constant MAX_CONSECUTIVE_FAILURES = 5;
    uint256 private constant RETRY_COOLDOWN = 30;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _owner, address _callbackSender)  // _callbackSender = Callback Proxy for this chain
        payable AbstractCallback(_callbackSender)
    {
        owner = _owner;
    }

    // Owner creates items (emits ItemConfigured → RC tracks it)
    function createItem(uint256 threshold) external onlyOwner returns (uint256) {
        uint256 id = nextId++;
        items.push(Item({ id: id, status: Status.Active, threshold: threshold,
                          lastAttempt: 0, consecutiveFailures: 0 }));
        emit ItemConfigured(id, threshold);
        return id;
    }

    function cancelItem(uint256 id) external onlyOwner {
        require(id < items.length, "No such item");
        items[id].status = Status.Cancelled;
        emit ItemCancelled(id);
    }

    function pauseItem(uint256 id) external onlyOwner {
        require(id < items.length && items[id].status == Status.Active, "Not active");
        items[id].status = Status.Paused;
        emit ItemPaused(id);
    }

    function resumeItem(uint256 id) external onlyOwner {
        require(id < items.length && items[id].status == Status.Paused, "Not paused");
        items[id].status = Status.Active;
        emit ItemResumed(id);
    }

    // Main entry point from RC
    function doWork(address /* sender */) external authorizedSenderOnly {
        uint256 executed = 0;
        uint256 checked = 0;

        for (uint256 i = 0; i < items.length; i++) {
            if (items[i].status != Status.Active) continue;
            checked++;
            try this._executeItem(i) returns (bool ok) {
                if (ok) executed++;
            } catch {
                emit ItemCheckFailed(i, "Unexpected error");
            }
        }

        emit CycleCompleted(block.timestamp, checked, executed);
    }

    function _executeItem(uint256 id) external returns (bool) {
        require(msg.sender == address(this), "Internal");
        Item storage item = items[id];
        if (item.lastAttempt > 0 &&
            block.timestamp < item.lastAttempt + RETRY_COOLDOWN) return false;
        item.lastAttempt = block.timestamp;

        bool success = _performWork(item);

        if (success) {
            item.consecutiveFailures = 0;
            emit ItemExecuted(id, 0 /* result */);
        } else {
            item.consecutiveFailures++;
            if (item.consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
                item.status = Status.Cancelled;
                emit ItemCancelled(id);
            }
        }
        return success;
    }

    function _performWork(Item storage item) internal returns (bool) {
        // ... actual business logic ...
        return true;
    }
}
```
