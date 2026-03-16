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
3. **Network tier** — Mainnet or testnet? Do not mix. Use Lasna Testnet (5318007) + Sepolia/Base Sepolia for testnet. Use Reactive Mainnet (1597) + Base/Ethereum/etc. for mainnet.
4. **Cron** — Does the RC need periodic triggering? If yes, pick one of these 5 block-interval cron topics (these are the ONLY options):

   | Event     | Interval          | Approx. Time | Topic 0                                                              |
   |-----------|-------------------|--------------|----------------------------------------------------------------------|
   | Cron1     | Every block       | ~7 sec       | `0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514` |
   | Cron10    | Every 10 blocks   | ~1 min       | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` |
   | Cron100   | Every 100 blocks  | ~12 min      | `0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70` |
   | Cron1000  | Every 1000 blocks | ~2 hr        | `0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4` |
   | Cron10000 | Every 10000 blocks| ~28 hr       | `0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56` |

   Cron topic is **immutable** — set it in the constructor and never change it.
5. **RC state** — What does the RC need to remember? Keep it minimal. All state must be initialized in the constructor; `react()` will never see state written by later transactions.
6. **CC lifecycle events** — What events does the CC emit that the RC needs to react to? Define these upfront; both sides need to agree on the signatures.

---

## 3. RC Contract Template

> **Import paths:** Use `"reactive-lib/src/..."` with a remapping in `foundry.toml` or `remappings.txt`. See `references/deployment.md` Step 0 for setup.
>
> **Event topic hashes:** Verify event topic_0 hashes with `cast keccak "EventName(type1,type2)"`. Do NOT use Node.js `crypto.createHash('sha3-256')` (that's NIST SHA3, not Ethereum's keccak256). **Cron topic hashes are protocol-defined constants** — do not try to compute them, use the values from the table in Section 2.

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
        address _callbackSender   // Callback Proxy address for this destination chain
    ) payable AbstractCallback(_callbackSender) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ── Main entry point from RC ─────────────────────────────────────────────
    // authorizedSenderOnly checks that msg.sender is the chain's Callback Proxy
    // (which was passed as _callbackSender to AbstractCallback in the constructor).
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
- **Every CC function called by the RC must have `address` as its first parameter** — this is the RVM ID sender slot, not a business parameter. Add it even if your function doesn't need it: `function doWork(address /* sender */, uint256 myParam) external authorizedSenderOnly`. The RC's payload must pass `address(0)` for this slot: `abi.encodeWithSignature("doWork(address,uint256)", address(0), myParam)`.
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
6. **Mandatory `address` sender as first parameter in ALL callback targets** — every function called via `emit Callback(...)` — whether on the CC or as a self-callback — MUST have `address` as its **first parameter** (the RVM ID slot). This is NOT a business parameter — it is an extra parameter prepended to your actual args. In the RC payload, always pass `address(0)` for this slot (RN replaces it with the RVM ID). Example: if your business logic needs `(address greeter, string message)`, the CC function signature must be `acknowledge(address sender, address greeter, string message)` and the RC payload must be `abi.encodeWithSignature("acknowledge(address,address,string)", address(0), greeter, message)`.
7. **`if (!vm)` in constructor** — always wrap `service.subscribe()` calls with this guard.
8. **Constructor must be `payable`** — RC needs ETH for callback delivery costs.
9. **Minimum callback gas is 100,000** — always set `CALLBACK_GAS_LIMIT` to at least 100,000. Use 1,000,000–2,000,000 for complex CC logic.
10. **Never mix mainnet and testnet** — Lasna Testnet RC can only call testnet chains; Reactive Mainnet RC can only call mainnet chains.
11. **`_callbackSender` = the Callback Proxy for the destination chain** — each chain has a specific Callback Proxy address that delivers callbacks to CCs. Pass that chain's proxy as `_callbackSender` to `AbstractCallback`. Example: CC on Sepolia → `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`. CC on Base → `0x0D3E76De6bC44309083cAAFdB49A088B8a250947`. See `references/architecture.md` for the full table. This is NOT your wallet address.

> See `references/gotchas.md` for full details with debugging context.

---

## 6. Reference Files

- **`references/architecture.md`** — `LogRecord` struct, modifier system (`vmOnly`/`rnOnly`/`callbackOnly`), `ISystemContract` API, `AbstractPausableReactive`/`AbstractCallback` internals, payment infrastructure, chain IDs, cron topic hashes, fee economics, DIA oracle.
- **`references/deployment.md`** — Step-by-step deployment guide: install, env vars, get lREACT, deploy CC, deploy RC, fund RC, verify on Reactscan.
- **`references/rc-patterns.md`** — Constructor patterns, topic_0 computation, `react()` routing, self-callback for state persistence, lazy cron subscription, `getPausableSubscriptions()`, duplicate event guard.
- **`references/cc-patterns.md`** — `AbstractCallback` inheritance, `authorizedSenderOnly` entry point, try-catch isolation, lifecycle events, consecutive failure + auto-cancel, retry cooldown, `CycleCompleted` guarantee.
- **`references/gotchas.md`** — 12 critical pitfalls discovered through real debugging. Read before writing any RC.

---

## 7. Examples

- **`examples/BasicDemoReactive.sol`** — Minimal RC: subscribes to `Ping` events, dispatches a `pong()` callback. Start here for "hello world".
- **`examples/BasicDemoCallback.sol`** — Minimal CC: emits `Ping`, receives `pong()` callback from RC, emits `Pong`. Paired with `BasicDemoReactive`.
- **`examples/UniswapDemoStopOrderReactive.sol`** — Simple RC: monitors Uniswap V2 Sync events, triggers a stop-order swap when price crosses threshold.
- **`examples/UniswapDemoStopOrderCallback.sol`** — Simple CC: executes a Uniswap token swap on Sepolia.
- **`examples/AaveProtectionReactive.sol`** — Complex RC: cron-based periodic health check, lazy cron subscription, self-callbacks for state persistence, subscribe/unsubscribe management in `callbackOnly` functions.
- **`examples/AaveProtectionCallback.sol`** — Complex CC: multi-config management, retry cooldown, consecutive failure tracking, auto-cancel, always emits `ProtectionCycleCompleted`.

---

## 8. Implementation Workflow

0. **Decide network tier** — testnet (Lasna + Sepolia/Base Sepolia) or mainnet (Reactive + Base/ETH/etc.). Never mix.
1. **Define the event surface** — list all events the RC subscribes to (origin chain) and all lifecycle events the CC emits (feedback loop).
2. **Deploy CC first** — it's a normal Solidity contract with no RN dependencies except `AbstractCallback`. Pass the **Callback Proxy address** for the destination chain as `_callbackSender` (see `references/architecture.md` for the per-chain table). Save the CC address.
3. **Derive topic_0 constants** — Use `cast keccak "EventSignature(type1,type2,...)"` for each event the RC needs. Never use Node.js SHA3-256 — it produces wrong hashes.
4. **Write and deploy the RC** — constructor subscriptions, `react()` routing, self-callback helpers, `callbackOnly` persist functions, `getPausableSubscriptions()`. Deploy with `--value` to pre-fund callback delivery.
5. **Verify the state model** — for each piece of RC state, ask: "Does `react()` need to read this?" If yes, it must be `immutable` or set in the constructor. If no, it's fine as mutable (written by `callbackOnly`).
6. **Verify on Reactscan** — check RC status is `active` at `https://lasna.reactscan.net/address/<RC_ADDRESS>`.

> See `references/deployment.md` for full deployment commands.
