# Deployment Guide — Reactive Network

Complete walkthrough from zero to a deployed RC+CC system on testnet.

> **Deployment order:** Always deploy CC first (you need its address for the RC constructor), then deploy RC.

---

## Step 0 — Project Setup

```bash
# Initialize a foundry project (skip if you already have one)
forge init my-reactive-project
cd my-reactive-project

# Install the reactive-lib dependency
forge install Reactive-Network/reactive-lib
```

Add remappings to your `foundry.toml` (or `remappings.txt`):

```toml
# foundry.toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc = "0.8.20"

# Add if using remappings.txt instead:
# remappings = ["reactive-lib/=lib/reactive-lib/"]
```

Or create `remappings.txt`:
```
reactive-lib/=lib/reactive-lib/
```

This allows you to import with `import "reactive-lib/src/..."` in your contracts.

---

## Step 1 — Set Required Environment Variables

```bash
# Your deployer wallet private key (same key for all networks recommended)
export PRIVATE_KEY=<your_private_key>

# Derive your wallet address (this is also your RVM ID)
export DEPLOYER_ADDR=$(cast wallet address --private-key $PRIVATE_KEY)

# Reactive Lasna Testnet (RC lives here)
export REACTIVE_RPC=https://lasna-rpc.rnk.dev/

# Sepolia (testnet destination chain for CC)
export SEPOLIA_RPC=<your_sepolia_rpc_url>

# Base Sepolia (alternative testnet destination)
export BASE_SEPOLIA_RPC=<your_base_sepolia_rpc_url>
```

> **Use the same private key for all networks.** RVM ID = deployer wallet address. Using the same key everywhere means your `$DEPLOYER_ADDR` is your RVM ID on every chain.

---

## Step 2 — Get lREACT Testnet Tokens

lREACT is the testnet gas token for Lasna. Obtain it by sending Sepolia ETH to the faucet.

```bash
# Sepolia faucet — 100 lREACT per 1 ETH sent. Max 5 ETH (= 500 lREACT) per tx.
export SEPOLIA_FAUCET=0x9b9BB25f1A81078C544C829c5EB7822d747Cf434
cast send $SEPOLIA_FAUCET --value 1ether \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# Base Sepolia faucet (alternative)
export BASE_FAUCET=0x2afaFD298b23b62760711756088F75B7409f5967
cast send $BASE_FAUCET --value 1ether \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY
```

> **Warning:** Sending more than 5 ETH per transaction to the faucet loses the excess permanently. Send in multiple transactions if you need more than 500 lREACT.

lREACT appears in your wallet on Lasna Testnet (chain ID 5318007) after a few confirmations.

---

## Step 3 — Deploy CC (Callback Contract) on Destination Chain

Deploy first — you need the CC address as a constructor argument for the RC.

```bash
forge create src/MyCallback.sol:MyCallback \
  --constructor-args $DEPLOYER_ADDR $DEPLOYER_ADDR \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY
```

- First arg: `owner` — who can manage the CC (your wallet)
- Second arg: `_callbackSender` — the RVM ID (your wallet address, same as deployer)

```bash
# Save the deployed address from the output
export CC_ADDRESS=<deployed_address_from_output>
```

---

## Step 4 — Deploy RC (Reactive Contract) on Lasna, Pre-fund with ETH

```bash
forge create src/MyReactive.sol:MyReactive \
  --constructor-args $DEPLOYER_ADDR $CC_ADDRESS \
  --value 0.1ether \
  --rpc-url $REACTIVE_RPC \
  --private-key $PRIVATE_KEY
```

- `--value 0.1ether` pre-funds the RC for callback delivery
- Constructor must be `payable`

```bash
export RC_ADDRESS=<deployed_address_from_output>
```

### Fund RC Later (if needed)

```bash
cast send $RC_ADDRESS --value 0.05ether \
  --rpc-url $REACTIVE_RPC --private-key $PRIVATE_KEY
```

---

## Step 5 — Verify on Reactscan

```
https://lasna.reactscan.net/address/<RC_ADDRESS>
```

Check the contract status:
- `active` — RC has funds; callbacks are being delivered
- `blocklisted` — RC is out of funds; no execution until re-funded

---

## BasicDemo End-to-End (Hello World)

A complete walkthrough using the BasicDemo example contracts:

```bash
# 1. Deploy BasicDemoCallback on Sepolia
forge create src/BasicDemoCallback.sol:BasicDemoCallback \
  --constructor-args $DEPLOYER_ADDR $DEPLOYER_ADDR \
  --rpc-url $SEPOLIA_RPC \
  --private-key $PRIVATE_KEY

export CC_ADDRESS=<deployed_address>

# 2. Deploy BasicDemoReactive on Lasna with CC_ADDRESS
forge create src/BasicDemoReactive.sol:BasicDemoReactive \
  --constructor-args $CC_ADDRESS \
  --value 0.1ether \
  --rpc-url $REACTIVE_RPC \
  --private-key $PRIVATE_KEY

export RC_ADDRESS=<deployed_address>

# 3. Trigger a Ping on Sepolia
cast send $CC_ADDRESS "ping(uint256)" 42 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# 4. Wait ~30-60 seconds, then check for Pong event
cast logs --from-block latest --address $CC_ADDRESS \
  --rpc-url $SEPOLIA_RPC

# 5. Verify RC status
echo "https://lasna.reactscan.net/address/$RC_ADDRESS"
```

---

## Quick Reference

**Cron topic hashes** — see `references/architecture.md` for the full table. Common ones:

| Interval  | Topic Hash                                                             |
|-----------|------------------------------------------------------------------------|
| 1 minute  | `0x10f4e58e062105477d72f60b69049586448b6c43bf40e7c334b1093b0e965d57`  |
| 5 minutes | `0x397d353798eb2ffcee4f62aad18906fd441cb6813b7d145398d4f170b6b976c2`  |
| 1 hour    | `0x1c0a1b9e81bd760da4242b10e7a82d11ddfba3691c444fb8c451375f6642c1bd`  |

**Chain IDs** — see `references/architecture.md` for the full table.

| Network              | Chain ID  | Tier     |
|----------------------|-----------|----------|
| Lasna Testnet (RC)   | 5318007   | Testnet  |
| Reactive Mainnet (RC)| 1597      | Mainnet  |
| Sepolia              | 11155111  | Testnet  |
| Base Sepolia         | 84532     | Testnet  |

> Testnet RC (Lasna) -> testnet destination only. Mainnet RC -> mainnet destination only.
