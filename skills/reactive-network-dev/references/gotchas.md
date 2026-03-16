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

## Gotcha 6: address(0) in Callback Payloads

**The rule:** Always use `address(0)` as the **first parameter** in `abi.encodeWithSignature(...)` calls within `emit Callback(...)`. The Reactive Network replaces this at execution time with the actual RVM ID (for self-callbacks) or the authorized sender (for CC callbacks).

**Pattern:**
```solidity
// Self-callback
emit Callback(
    block.chainid,
    address(this),
    GAS_LIMIT,
    abi.encodeWithSignature(
        "persistConfigCreated(address,uint256,uint256)",
        address(0),  // ← MUST be address(0); RN injects RVM ID here
        configId,
        threshold
    )
);

// Outbound callback to CC
emit Callback(
    DEST_CHAIN_ID,
    callbackContract,
    GAS_LIMIT,
    abi.encodeWithSignature(
        "checkAndProtect(address)",
        address(0)  // ← MUST be address(0); RN injects RVM ID here
    )
);
```

On the CC side, the function receives the actual RVM ID as the first argument:
```solidity
function checkAndProtect(address /* sender */) external authorizedSenderOnly {
    // sender is the RVM ID, which AbstractCallback validates
}
```

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

## Gotcha 12: RVM ID is Your Deployer Address

**The rule:** The RVM ID (passed to the CC's `AbstractCallback` constructor as `_callbackSender`) is simply the **EOA address used to deploy the RC**. It is not a separate identifier to look up.

**What breaks:**
```solidity
// BAD — using the RC's deployed contract address
constructor(address _callbackSender) AbstractCallback(_callbackSender) {}
// deployed with: --constructor-args $OWNER $RC_CONTRACT_ADDRESS
// ↑ Wrong. The CC rejects all callbacks because RVM ID ≠ RC address.
```

**Fix:**
```bash
# Deploy CC with the wallet address that will deploy the RC
forge create src/MyCallback.sol:MyCallback \
  --constructor-args $OWNER $DEPLOYER_WALLET_ADDRESS \
  --rpc-url $SEPOLIA_RPC \
  --private-key $SEPOLIA_PRIVATE_KEY
```

If you accidentally use a different deployer address for the RC than you passed to the CC, the CC will silently reject all callbacks from `authorizedSenderOnly`.

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
