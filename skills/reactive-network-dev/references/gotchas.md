# Critical Gotchas — Reactive Network Development

These pitfalls were discovered through real debugging. Each one cost significant time. Read this before writing any RC.

---

## Gotcha 1: VM Only Reads Constructor-Initialized State

**The rule:** `react()` runs in an isolated ReactVM snapshot taken at deployment. Any state written after deployment — by `callbackOnly`, `rnOnly`, or any other transaction — is **completely invisible** to `react()`.

**What breaks:**
```solidity
// BAD — activeConfigCount is written by callbackOnly, react() always sees 0
function react(LogRecord calldata log) external vmOnly {
    if (activeConfigCount == 0) return; // ALWAYS returns — never executes
    // ...
}
```

**Fix:**
- Never put guards in `react()` that depend on post-deployment state
- If `react()` needs to know "are there active items?", use subscription presence as the signal: subscribe to cron when the first item activates, unsubscribe when the last item is cancelled. If cron fires, there must be active items.
- Only `immutable` variables and constructor-assigned values are safe to read in `react()`

**How we discovered this:** `activeConfigCount` was incrementing correctly in `persistConfigCreated` (verified via on-chain events), but `react()` never triggered the health check because the guard `if (activeConfigCount == 0) return` always evaluated to true. Took hours to realize the ReactVM has a frozen state snapshot.

---

## Gotcha 2: Nested Callbacks Are Silently Dropped

**The rule:** If a `callbackOnly` function emits a `Callback` event, the RN does **not** process it. Only `Callback` events emitted from `react()` (vmOnly context) are dispatched.

**What breaks:**
```solidity
// BAD — the Callback emitted here is silently ignored
function persistConfigCreated(address /* sender */, uint256 id) external callbackOnly {
    isTracked[id] = true;
    // This Callback will NEVER be executed:
    emit Callback(block.chainid, address(this), GAS_LIMIT,
        abi.encodeWithSignature("subscribeToCron(address)", address(0)));
}
```

**Fix:**
Call `service.subscribe()` directly from `callbackOnly` — no need for a nested callback:
```solidity
function persistConfigCreated(address /* sender */, uint256 id) external callbackOnly {
    isTracked[id] = true;
    activeCount++;
    if (activeCount == 1 && !cronSubscribed) {
        service.subscribe(block.chainid, address(service), cronTopic, ...);
        cronSubscribed = true;
    }
}
```

**How we discovered this:** The `subscribeToCron` function was being emitted as a callback from `persistConfigCreated` but was never executing. No error, no revert — the callback was simply dropped. Discovered after adding extensive event logging and noticing `subscribeToCron` was never called.

---

## Gotcha 3: callbackOnly CAN Call service.subscribe Directly

**The rule:** `callbackOnly` functions run as real EVM transactions on the Reactive Network. They have full access to the system contract (`service`). You can call `service.subscribe()` and `service.unsubscribe()` directly from within them.

**Why this is counter-intuitive:** Developers assume that subscription management requires being "inside" the reactive loop (vmOnly context). Not true.

**The pattern:**
```solidity
function persistConfigCancelled(address /* sender */, uint256 id) external callbackOnly {
    activeCount--;
    if (activeCount == 0 && cronSubscribed) {
        // This WORKS — callbackOnly is a real transaction on RN
        service.unsubscribe(block.chainid, address(service), cronTopic,
            REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        cronSubscribed = false;
    }
}
```

This is the correct pattern for lazy cron subscription management.

---

## Gotcha 4: cronTopic in react() Always Reads the Constructor Value

**The rule:** Even if you add a `setCronTopic(uint256)` function and call it, `react()` will always compare `log.topic_0` against the value that was in `cronTopic` at constructor time. Any storage write is invisible to the ReactVM.

**What breaks:**
```solidity
uint256 public cronTopic;  // NOT immutable

function setCronTopic(uint256 newTopic) external rnOnly onlyOwner {
    cronTopic = newTopic;  // Writes to storage
}

function react(LogRecord calldata log) external vmOnly {
    if (log.topic_0 == cronTopic) {  // ALWAYS reads original constructor value
        // ...
    }
}
```

Calling `setCronTopic` will update on-chain storage (visible to view functions and callbackOnly), but `react()` will never match the new topic.

**Fix:**
- Declare `cronTopic` as `immutable`
- If you need to change cron frequency, redeploy with a new `_cronTopic` constructor argument
- In the Aave Protection RC, `setCronTopic` exists but only correctly handles the subscription update; the `react()` matching will break if called. This is a known limitation documented in the codebase.

---

## Gotcha 5: Use Subscription Presence as the Active Guard

**The rule:** Don't check `activeCount > 0` in `react()` (broken — VM constraint #1). Instead, design so that the cron subscription only exists when there are active items.

**Pattern:**
- Subscribe to cron in `persistItemCreated` when `activeCount` goes from 0 to 1
- Unsubscribe from cron in `persistItemCancelled`/`persistItemPaused` when `activeCount` goes to 0
- `react()` never needs to check a counter — if cron fired, active items exist by definition

```solidity
// In callbackOnly persist functions:
if (activeCount == 1 && !cronSubscribed) {
    service.subscribe(...cronTopic...);
    cronSubscribed = true;
}
// and on removal:
if (activeCount == 0 && cronSubscribed) {
    service.unsubscribe(...cronTopic...);
    cronSubscribed = false;
}
```

This pattern keeps `react()` simple and correct.

---

## Gotcha 6: Every Callback Target Must Have `address` as First Parameter (Sender Slot)

**The rule:** Every function called via `emit Callback(...)` — whether on the CC or as a self-callback on the RC — **MUST have `address` as its first parameter**. This is the sender/RVM ID slot. The Reactive Network injects the RVM ID into this slot at execution time. In the RC's payload, always pass `address(0)` for this slot.

**This is an EXTRA parameter.** If your business logic needs `(address greeter, string message)`, the target function signature must be `fn(address sender, address greeter, string message)` — three params, not two. The `address sender` is prepended.

**What breaks:**
```solidity
// BAD — CC function missing the sender slot
// CC side:
function acknowledge(address greeter, string calldata message) external authorizedSenderOnly { ... }
// RC side:
abi.encodeWithSignature("acknowledge(address,string)", greeter, message)
// ↑ greeter gets replaced with RVM ID! Your actual greeter value is lost.
// authorizedSenderOnly may also fail because the injected sender doesn't match expectations.
```

**Correct pattern:**
```solidity
// GOOD — sender slot is explicit and separate from business params

// CC side — address as first param, then business params:
function acknowledge(address /* sender */, address greeter, string calldata message) external authorizedSenderOnly {
    // sender is RVM ID (validated by authorizedSenderOnly)
    // greeter and message are your actual business data
    emit Acknowledged(greeter, message);
}

// RC side — address(0) first, then business args:
emit Callback(
    DEST_CHAIN_ID,
    callbackContract,
    GAS_LIMIT,
    abi.encodeWithSignature(
        "acknowledge(address,address,string)",  // ← note: address appears TWICE
        address(0),  // ← sender slot; RN replaces with RVM ID
        greeter,     // ← actual business param
        message      // ← actual business param
    )
);
```

**Same rule for self-callbacks on the RC:**
```solidity
// RC self-callback target:
function persistItem(address /* sender */, uint256 itemId, uint256 threshold) external callbackOnly { ... }

// RC payload in react():
emit Callback(
    block.chainid,
    address(this),
    GAS_LIMIT,
    abi.encodeWithSignature(
        "persistItem(address,uint256,uint256)",
        address(0),  // ← sender slot
        itemId,
        threshold
    )
);
```

**How we discovered this:** Generated a CC with `acknowledge(address greeter, string message)` where `greeter` was a business param. The RN overwrote `greeter` with the RVM ID, so the CC received the wrong address. The function signature in `encodeWithSignature` also didn't match because it had `(address,string)` instead of `(address,address,string)`.

**Checklist:** For every `emit Callback(...)` in the RC, count the params:
1. The function signature in `encodeWithSignature` must start with `address,`
2. The first value arg after the signature string must be `address(0)`
3. The target function must have `address` (or `address /* sender */`) as its first parameter
4. Business params come after the sender slot in both the signature and the function

---

## Gotcha 7: Constructor Must Be payable

**The rule:** The RC constructor must be `payable`. Deploy it with ETH to pre-fund callback delivery costs. If no ETH is provided, the first callback dispatch may fail or accumulate debt.

```solidity
constructor(
    address _owner,
    address _callbackContract,
    uint256 _cronTopic
) payable {  // ← must be payable
    // ...
}
```

**Deploy with ETH:**
```bash
forge create MyReactive --value 0.1ether --constructor-args ...
```

Also add withdrawal functions for recovery:
```solidity
function withdrawAllETH() external onlyOwner {
    uint256 balance = address(this).balance;
    require(balance > 0, "No ETH");
    (bool ok,) = payable(msg.sender).call{value: balance}("");
    require(ok, "Transfer failed");
}
```

---

## Gotcha 8: if (!vm) in Constructor

**The rule:** Never call `service.subscribe()` unconditionally in the constructor. Always wrap with `if (!vm)`.

**Why:** When the contract is deployed or simulated in test/local environments, `vm` is `true` and `service` may not be available. Calling `service.subscribe()` without the guard causes a revert or undefined behavior in those contexts.

```solidity
constructor(...) payable {
    // ... set immutables ...

    if (!vm) {
        // Only called when actually deploying to RN mainnet/testnet
        service.subscribe(destinationChainId, callbackContract, topic, ...);
    }
}
```

The `vm` boolean is `false` on a live RN deployment (normal execution context) and `true` in the ReactVM simulation. The guard ensures subscriptions are only registered on live networks.

---

## Gotcha 9: Minimum Callback Gas is 100,000

**The rule:** The system enforces a minimum of 100,000 gas for any callback. Setting `CALLBACK_GAS_LIMIT` below this is silently raised to 100,000 or the callback is rejected.

**Always use at least 100,000.** For complex CC logic, use 1,000,000–2,000,000.

```solidity
// BAD — will be raised to 100,000 anyway, but don't rely on silent correction
uint64 private constant CALLBACK_GAS_LIMIT = 50_000;

// GOOD
uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;
```

---

## Gotcha 10: Never Mix Mainnet and Testnet Chains

**The rule:** Origin and destination chains must be from the same tier. A Lasna Testnet RC cannot deliver callbacks to Base Mainnet. A Reactive Mainnet RC cannot subscribe to Sepolia events.

**What breaks:** Subscribing to Sepolia (testnet) events and pointing `DEST_CHAIN_ID` at Base Mainnet (8453). The callback is simply never delivered — no error, no revert.

**Fix:** Use consistent tiers:
- Testnet: Lasna (5318007) + Sepolia (11155111) + Base Sepolia (84532) + Unichain Sepolia (1301)
- Mainnet: Reactive (1597) + Base (8453) + Ethereum (1) + etc.

---

## Gotcha 11: Faucet Limit — Max 5 ETH Per Transaction

**The rule:** The lREACT faucet gives 100 lREACT per 1 ETH sent. Sending more than 5 ETH in a single transaction (= 500 lREACT) causes the **excess to be lost permanently**.

**Fix:** Send in multiple transactions if you need more than 500 lREACT.

```bash
# Send 5 ETH max per transaction
cast send $SEPOLIA_FAUCET --value 5ether --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
# Wait for confirmation, then send again if needed
```

Faucet addresses:
- Sepolia: `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`
- Base Sepolia: `0x2afaFD298b23b62760711756088F75B7409f5967`

---

## Gotcha 12: `_callbackSender` is the Chain-Specific Callback Proxy, NOT Your Wallet

**The rule:** The `_callbackSender` passed to `AbstractCallback` in the CC constructor is the **Callback Proxy address for the destination chain where the CC is deployed**. Each chain has its own proxy. This is NOT your wallet address, NOT the RC address, NOT an "RVM ID".

**What breaks:**
```solidity
// BAD — passing deployer wallet address
constructor(address _owner, address _callbackSender) AbstractCallback(_callbackSender) {}
// deployed with: --constructor-args $OWNER $MY_WALLET_ADDRESS
// ↑ WRONG. authorizedSenderOnly rejects all callbacks because msg.sender is the proxy, not your wallet.
```

**Fix — use the Callback Proxy for the chain:**
```bash
# CC deployed on Sepolia → use Sepolia's Callback Proxy
SEPOLIA_CALLBACK_PROXY=0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA

forge create src/MyCallback.sol:MyCallback \
  --constructor-args $OWNER $SEPOLIA_CALLBACK_PROXY \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

**Common Callback Proxy addresses:**

| Destination Chain | Callback Proxy                               |
|-------------------|----------------------------------------------|
| Reactive (both)   | `0x0000000000000000000000000000000000fffFfF`  |
| Ethereum Sepolia  | `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`  |
| Base Sepolia      | `0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6`  |
| Unichain Sepolia  | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`  |
| Ethereum Mainnet  | `0x1D5267C1bb7D8bA68964dDF3990601BDB7902D76`  |
| Base Mainnet      | `0x0D3E76De6bC44309083cAAFdB49A088B8a250947`  |
| Arbitrum          | `0x4730c58FDA9d78f60c987039aEaB7d261aAd942E`  |

See `references/architecture.md` for the full table.

**How we discovered this:** CC deployed on Sepolia with deployer wallet as `_callbackSender`. Every callback from the RC was silently rejected by `authorizedSenderOnly` because `msg.sender` was the Sepolia Callback Proxy (`0xc9f3...`), not our wallet. No revert message visible — callbacks just disappeared.

---

## Bonus: Duplicate Event Guard

When the RC subscribes to events without tight topic filters, the same event can be delivered multiple times (e.g., due to reorgs or re-deliveries). Add a deduplication check:

```solidity
mapping(uint256 => bool) public isTracked;

function persistConfigCreated(address, uint256 configId, ...) external callbackOnly {
    if (isTracked[configId]) return;  // Skip duplicates
    isTracked[configId] = true;
    // ... rest of logic
}
```

Also use a `processedTxHashes` mapping if event-level deduplication is needed:
```solidity
mapping(uint256 => bool) public processedTxHashes;

function react(LogRecord calldata log) external vmOnly {
    if (processedTxHashes[log.tx_hash]) return;
    // Note: can't write processedTxHashes here (vmOnly, no state writes)
    // Instead, emit a self-callback that marks it in callbackOnly
}
```
