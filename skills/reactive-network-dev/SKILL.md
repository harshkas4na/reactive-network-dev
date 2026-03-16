---
description: >
  Use this skill when the user asks to:
  "write a reactive contract", "create an RC system", "build a reactive network contract",
  "scaffold RC and CC", "monitor chain events and trigger", "automate cross-chain",
  "cron-based automation on reactive network", "write a callback contract",
  "reactive smart contract for X"
---

# Reactive Network Development Skill

You are designing and implementing a **Reactive Network smart contract system**. Every system consists of exactly two contracts: a **Reactive Contract (RC)** deployed on the Reactive Network, and a **Callback Contract (CC)** deployed on the destination chain. Follow this guide precisely.

---

## 1. Overview

**Two-contract architecture:**

- **RC (Reactive Contract)** — deployed on the Reactive Network. Monitors events from any EVM chain via subscriptions. Its `react()` function runs in a sandboxed ReactVM whenever a subscribed event fires. The ONLY output from `react()` is `emit Callback(...)` — no state writes.
- **CC (Callback Contract)** — deployed on the destination chain (e.g., Base, Sepolia). Receives callbacks from the RC and executes on-chain actions. It emits lifecycle events that the RC subscribes back to, forming a feedback loop.

The RC and CC communicate exclusively via events. There is no direct call between them.

---

## 2. Design Checklist

Before writing any code, answer these questions:

1. **Origin chain** — Which chain(s) do the trigger events come from? What are the event signatures? Compute `topic_0 = keccak256("EventName(type1,type2,...)")`.
2. **Destination chain** — Where does execution happen? What is the CC address? (Known at deploy time or passed as constructor arg.)
3. **Cron** — Does the RC need periodic triggering? If yes, which cron topic? (Get cron topic hashes from RN docs or use `keccak256("reactive-network-cron-1min")` etc.) Cron topic is **immutable** — set it in the constructor and never change it.
4. **RC state** — What does the RC need to remember? Keep it minimal. All state must be initialized in the constructor; `react()` will never see state written by later transactions.
5. **CC lifecycle events** — What events does the CC emit that the RC needs to react to? Define these upfront; both sides need to agree on the signatures.

---

## 3. RC Contract Template

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "reactive-lib/src/interfaces/IReactive.sol";
import "reactive-lib/src/abstract-base/AbstractPausableReactive.sol";

contract MyReactive is IReactive, AbstractPausableReactive {

    // ── Events ──────────────────────────────────────────────────────────────
    event CallbackSent(uint256 indexed configId);
    event StatePersisted(uint256 indexed configId);

    // ── Constants ───────────────────────────────────────────────────────────
    uint256 private constant DEST_CHAIN_ID = 8453; // or pass as constructor arg
    uint256 private constant SOME_EVENT_TOPIC_0 =
        0x...; // keccak256("SomeEvent(address,uint256)")
    uint256 private constant LIFECYCLE_EVENT_TOPIC_0 =
        0x...; // keccak256("LifecycleEvent(uint256)")
    uint64  private constant CALLBACK_GAS_LIMIT = 2_000_000;
    address private constant RN_CALLBACK_PROXY =
        0x0000000000000000000000000000000000fffFfF;

    // ── Immutables (set in constructor, readable by react()) ─────────────────
    address public immutable callbackContract;
    uint256 public immutable cronTopic; // NEVER change after deploy

    // ── Mutable state (written by callbackOnly, INVISIBLE to react()) ────────
    bool    public cronSubscribed;
    uint256 public activeCount;
    mapping(uint256 => bool) public isTracked;

    modifier callbackOnly() {
        require(msg.sender == RN_CALLBACK_PROXY, "Callback proxy only");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _callbackContract,
        uint256 _cronTopic
    ) payable {
        owner = _owner;
        callbackContract = _callbackContract;
        cronTopic = _cronTopic;   // immutable; react() always reads this value
        cronSubscribed = false;
        activeCount = 0;

        if (!vm) {
            // Subscribe to CC lifecycle events
            service.subscribe(
                DEST_CHAIN_ID,
                callbackContract,
                LIFECYCLE_EVENT_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            // Add more subscriptions here as needed
            // DO NOT subscribe to cron here — do it lazily in persistXxx()
        }
    }

    // ── react() ─────────────────────────────────────────────────────────────
    // Runs in ReactVM. No state writes. Only emit Callback.
    function react(LogRecord calldata log) external vmOnly {
        // 1. Handle cron ticks first
        if (log.topic_0 == cronTopic) {
            _handleCronTick(log);
            return;
        }
        // 2. Filter by contract
        if (log._contract != callbackContract) return;
        // 3. Route by topic_0
        if (log.topic_0 == LIFECYCLE_EVENT_TOPIC_0) {
            _handleLifecycleEvent(log);
        }
        // Add more routes...
    }

    function _handleCronTick(LogRecord calldata log) internal {
        // Emit callback to CC — cron is only subscribed when active work exists
        emit Callback(
            DEST_CHAIN_ID,
            callbackContract,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature("doWork(address)", address(0))
        );
    }

    function _handleLifecycleEvent(LogRecord calldata log) internal {
        uint256 id = uint256(log.topic_1);
        // Emit self-callback to persist state — use address(0) as first arg
        emit Callback(
            block.chainid,
            address(this),
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSignature(
                "persistLifecycleEvent(address,uint256)",
                address(0),
                id
            )
        );
    }

    // ── callbackOnly state-persistence functions ─────────────────────────────
    // These run as real EVM transactions on RN. They CAN call service.subscribe/unsubscribe.
    // State written here is INVISIBLE to react().
    // Subscription management IS visible (it modifies the subscription table, not ReactVM state).

    function persistLifecycleEvent(
        address /* sender */,
        uint256 id
    ) external callbackOnly {
        if (isTracked[id]) return;
        isTracked[id] = true;
        activeCount++;

        // Subscribe to cron when first active item arrives
        if (activeCount == 1 && !cronSubscribed) {
            service.subscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronSubscribed = true;
        }
    }

    function persistItemCancelled(
        address /* sender */,
        uint256 id
    ) external callbackOnly {
        if (!isTracked[id]) return;
        activeCount--;
        if (activeCount == 0 && cronSubscribed) {
            service.unsubscribe(
                block.chainid,
                address(service),
                cronTopic,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            cronSubscribed = false;
        }
    }

    // ── getPausableSubscriptions ─────────────────────────────────────────────
    // Return ONLY the cron subscription (if active). The base class handles
    // pause/resume of these subscriptions.
    function getPausableSubscriptions()
        internal
        view
        override
        returns (Subscription[] memory)
    {
        if (!cronSubscribed) return new Subscription[](0);
        Subscription[] memory subs = new Subscription[](1);
        subs[0] = Subscription(
            block.chainid,
            address(service),
            cronTopic,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        return subs;
    }
}
```

**RC state rules:**
- `immutable` variables: set in constructor, always readable by `react()`
- Regular state variables written by `callbackOnly`/`rnOnly`: **NEVER readable by `react()`**
- Only subscriptions managed by `callbackOnly` take effect for future `react()` calls

---

## 4. CC Contract Template

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "reactive-lib/src/abstract-base/AbstractCallback.sol";

contract MyCallback is AbstractCallback {

    // ── Lifecycle events (RC subscribes to these) ───────────────────────────
    event ItemConfigured(uint256 indexed id, uint256 param);
    event ItemExecuted(uint256 indexed id, uint256 result);
    event ItemCancelled(uint256 indexed id);
    event CycleCompleted(uint256 timestamp, uint256 checked, uint256 executed);

    address public immutable owner;
    uint8 private constant MAX_CONSECUTIVE_FAILURES = 5;
    uint256 private constant RETRY_COOLDOWN = 30;

    constructor(
        address _owner,
        address _callbackSender   // RVM ID — passed as _callbackSender to AbstractCallback
    ) payable AbstractCallback(_callbackSender) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ── Main entry point from RC ─────────────────────────────────────────────
    // authorizedSenderOnly checks that msg.sender is the RN callback proxy
    // and that the injected sender (first arg) matches the RVM ID.
    function doWork(address /* sender */) external authorizedSenderOnly {
        uint256 executed = 0;
        uint256 checked = 0;

        // Iterate over work items
        for (uint256 i = 0; i < items.length; i++) {
            checked++;
            try this._executeItem(i) returns (bool ok) {
                if (ok) executed++;
            } catch {
                // Catch all; item-level failure should not abort the cycle
            }
        }

        // ALWAYS emit CycleCompleted — RC needs this to reset processing state
        emit CycleCompleted(block.timestamp, checked, executed);
    }

    // External so try-catch works. Guard with address(this) check.
    function _executeItem(uint256 id) external returns (bool) {
        require(msg.sender == address(this), "Internal function");
        // ... business logic ...
        return true;
    }
}
```

**CC rules:**
- Always emit `CycleCompleted` (or equivalent) even when nothing executed — RC uses it to reset state
- Use `try this._externalFn(...)` pattern for per-item isolation
- Guard `_externalFn` with `require(msg.sender == address(this))`
- After `MAX_CONSECUTIVE_FAILURES`, emit a cancel event so RC can unsubscribe from cron

---

## 5. Key Rules (Critical Gotchas)

1. **`react()` is frozen at deploy-time** — it only sees constructor-initialized state. Never put guards in `react()` that depend on state written after deployment.
2. **No nested callbacks** — `callbackOnly` functions cannot emit `Callback` events that get dispatched. Call `service.subscribe/unsubscribe` directly from `callbackOnly` instead.
3. **`callbackOnly` CAN call `service.subscribe`** — counter-intuitive but confirmed. Use this for all subscription management.
4. **`cronTopic` is permanent** — `react()` always reads the constructor value. Exposing `setCronTopic` that writes to storage is misleading; it won't affect `react()`.
5. **Subscription presence = active guard** — instead of checking `activeCount > 0` in `react()` (broken), unsubscribe from cron when the last item is cancelled. No subscription = no cron calls.
6. **`address(0)` in self-callbacks** — always use `address(0)` as the first parameter in `abi.encodeWithSignature(...)` for self-callbacks. RN replaces it with the actual RVM ID.
7. **`if (!vm)` in constructor** — always wrap `service.subscribe()` calls with this guard.
8. **Constructor must be `payable`** — RC needs ETH for callback delivery costs.

> See `references/gotchas.md` for full details with debugging context.

---

## 6. Reference Files

- **`references/architecture.md`** — `LogRecord` struct, modifier system (`vmOnly`/`rnOnly`/`callbackOnly`), `ISystemContract` API, `AbstractPausableReactive`/`AbstractCallback` internals, payment infrastructure, chain IDs.
- **`references/rc-patterns.md`** — Constructor patterns, topic_0 computation, `react()` routing, self-callback for state persistence, lazy cron subscription, `getPausableSubscriptions()`, duplicate event guard.
- **`references/cc-patterns.md`** — `AbstractCallback` inheritance, `authorizedSenderOnly` entry point, try-catch isolation, lifecycle events, consecutive failure + auto-cancel, retry cooldown, `CycleCompleted` guarantee.
- **`references/gotchas.md`** — 8 critical pitfalls discovered through real debugging. Read before writing any RC.

---

## 7. Examples

- **`examples/UniswapDemoStopOrderReactive.sol`** — Simple RC: monitors Uniswap V2 Sync events, triggers a stop-order swap when price crosses threshold. Good baseline for event-triggered RCs.
- **`examples/UniswapDemoStopOrderCallback.sol`** — Simple CC: executes a Uniswap token swap on Sepolia.
- **`examples/AaveProtectionReactive.sol`** — Complex RC: cron-based periodic health check, lazy cron subscription, self-callbacks for state persistence, subscribe/unsubscribe management in `callbackOnly` functions.
- **`examples/AaveProtectionCallback.sol`** — Complex CC: multi-config management, retry cooldown, consecutive failure tracking, auto-cancel, always emits `ProtectionCycleCompleted`.

---

## 8. Implementation Workflow

1. **Define the event surface** — list all events the RC subscribes to (origin chain) and all lifecycle events the CC emits (feedback loop).
2. **Write the CC first** — it's a normal Solidity contract with no RN dependencies except `AbstractCallback`. Get the logic right here.
3. **Derive topic_0 constants** — `keccak256("EventSignature(type1,type2,...)") for each event the RC needs.
4. **Write the RC** — constructor subscriptions, `react()` routing, self-callback helpers, `callbackOnly` persist functions, `getPausableSubscriptions()`.
5. **Verify the state model** — for each piece of RC state, ask: "Does `react()` need to read this?" If yes, it must be `immutable` or set in the constructor. If no, it's fine as mutable (written by `callbackOnly`).
6. **Fund the RC** — deploy with ETH to cover callback costs. Add `withdrawAllETH()` for recovery.
