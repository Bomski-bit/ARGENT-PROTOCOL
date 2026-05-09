# Argent Protocol

A decentralised, non-custodial lending and borrowing protocol with on-chain governance, built on Base (Sepolia testnet). Users deposit collateral, borrow assets against it. All protocol parameters are governed by ARG token holders through the Senate DAO.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Core Contracts](#core-contracts)
- [Getting Started](#getting-started)
- [Environment Setup](#environment-setup)
- [Running Tests](#running-tests)
- [Deployment](#deployment)
- [Security Analysis](#security-analysis)
- [Governance](#governance)
- [Protocol Parameters](#protocol-parameters)
- [Known Limitations](#known-limitations)
- [Audit Notes](#audit-notes)

---

## Overview

Argent Protocol allows users to:

- **Deposit collateral** — lock supported assets (WETH, WBTC, USDC, USDT, DAI, LINK) as collateral
- **Borrow** — draw loans against deposited collateral up to the asset's LTV ratio
- **Provide liquidity** — deposit assets into the lending pool
- **Repay** — return borrowed assets plus accrued interest at any time
- **Liquidate** — repay part of an undercollateralised position in exchange for discounted collateral

All admin functions (fee changes, asset listings, oracle updates, treasury withdrawals) require a governance vote through the Senate and a timelock delay before execution.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GOVERNANCE LAYER                             │
│                                                                     │
│  ┌──────────────┐    propose/vote    ┌───────────────────────────┐  │
│  │   ARG Token  │ ─────────────────► │  Senate (Governor)        │  │
│  │  (Argentum)  │                    │  - 1 day voting delay     │  │
│  └──────────────┘                    │  - 7 day voting period    │  │
│         │                            │  - 4% quorum              │  │
│         │ holds                      │  - 500 ARG threshold      │  │
│         ▼                            └──────────────┬────────────┘  │
│  ┌──────────────┐                                   │ queue         │
│  │   Treasury   │                                   ▼               │
│  │  (holds ARG) │                    ┌───────────────────────────┐  │
│  └──────────────┘                    │  ArgentTimelock           │  │
│                                      │  - 2 day execution delay  │  │
│                                      └──────────────┬────────────┘  │
└─────────────────────────────────────────────────────┼───────────────┘
                                                      │ executes
                          ┌───────────────────────────┼────────────────┐
                          │       PROTOCOL LAYER      │                │
                          │                           ▼                │
                          │  ┌──────────────────────────────────────┐  │
                          │  │         ArgentProtocol               │  │
                          │  │  - Collateral management             │  │
                          │  │  - Borrow / repay                    │  │
                          │  │  - Interest accrual (index-based)    │  │
                          │  │  - Health factor calculation         │  │
                          │  │  - Liquidations                      │  │
                          │  └──────────┬────────────┬──────────────┘  │
                          │             │            │                 │
                          │             ▼            ▼                 │
                          │  ┌──────────────┐  ┌───────────────┐       │
                          │  │ PriceOracle  │  │   Treasury    │       │
                          │  │  Chainlink   │  │  fee receiver │       │
                          │  │  aggregators │  └───────────────┘       │
                          │  └──────────────┘                          │
                          └────────────────────────────────────────────┘
```

---

## Project Structure

```
argent-protocol/
├── src/
│   ├── interfaces/
│   │   └── IPriceOracle.sol
│   ├── ArgentProtocol.sol
│   ├── ArgentTimelock.sol
│   ├── Argentum.sol
│   ├── PriceOracle.sol
│   ├── Senate.sol
│   └── Treasury.sol
├── script/
│   └── DeployArgentProtocol.s.sol
├── test/
│   ├── unit/
│   │   ├── ArgentProtocolTest.t.sol         
|   |   ├── ArgentumTest.t.sol               
|   |   ├── DeployArgentProtocolTest.t.sol    
|   |   ├── PriceOracleTest.t.sol             
|   |   ├── SenateTest.t.sol                  
|   |   └── TreasuryTest.t.sol
│   ├── invariant/
│   │   ├── ArgentProtocolInvariantTest.t.sol
│   │   └── ArgentHandler.sol
│   └── mocks/
│       ├── MockERC20.sol
│       ├── MockERC20Votes.sol
│       ├── MockPriceOracle.sol
│       └── RevertingMockFeed.sol
├── foundry.toml
└── README.md
```

---

## Core Contracts

### `ArgentProtocol.sol`
The central lending engine. Manages collateral deposits, liquidity pools, borrowing, repayment, interest accrual, and liquidations.

Key design decisions:
- **Index-based interest** — a global `borrowIndex` per asset accumulates interest over time. User debt is scaled by `(currentIndex / userIndex)` at read time, avoiding per-user storage updates.
- **Weighted liquidation threshold** — when a user holds multiple collateral assets, the liquidation threshold is a USD-weighted average across all positions.
- **Cap-and-scale liquidation** — when the liquidation bonus would require more collateral than the user has, the seize amount is capped and the repay amount is scaled down proportionally. This prevents positions from becoming permanently unliquidatable.
- **`totalBorrows` accounting** — tracks stored user debt including capitalised interest. When partial repayments occur, accrued interest is synced into `totalBorrows` before subtraction to prevent arithmetic underflow.

### `Argentum.sol`
ERC20 governance token with ERC20Votes (delegation), ERC20Permit (gasless approvals), and ERC20Burnable. Fixed supply capped at `MAX_SUPPLY`. The `mint()` function allows the owner (Timelock) to issue tokens up to the cap for future incentive programmes.

### `Senate.sol`
OpenZeppelin Governor with the following extensions:
- `GovernorSettings` — configurable voting delay, period, and threshold
- `GovernorCountingSimple` — for/against/abstain vote counting
- `GovernorVotes` — ARG token voting weight
- `GovernorVotesQuorumFraction` — percentage-based quorum
- `GovernorTimelockControl` — routes execution through ArgentTimelock

### `ArgentTimelock.sol`
Extends OpenZeppelin `TimelockController`. Enforces a minimum delay between a proposal passing and its execution. Proposer and Canceller roles are granted exclusively to Senate. The admin role is revoked from the deployer after setup.

### `Treasury.sol`
Holds protocol-owned assets including the full ARG token supply. Protected by `ReentrancyGuard`. All withdrawals require a governance vote. Supports both ERC20 and ETH transfers.

### `PriceOracle.sol`
Wraps Chainlink `AggregatorV3Interface` feeds. Per-asset heartbeat configuration. Reverts on stale prices, future timestamps, zero prices, and feed unavailability. Implements `IPriceOracle` from `src/interfaces/IPriceOracle.sol`.

---

## Getting Started

### Prerequisites

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Python (for Slither)
sudo apt install python3.10-venv -y
python3 -m venv slither-env
source slither-env/bin/activate
pip install slither-analyzer

# Rust (for Aderyn)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
cargo install aderyn
```

### Clone and Install

```bash
git clone https://github.com/Bomski-bit/argent-protocol
cd argent-protocol
forge install
```

### Build

```bash
forge build

# Check contract sizes (24KB EVM limit)
forge build --sizes
```

> **Note:** `via_ir = true` is required in `foundry.toml` due to the Senate contract exceeding the 24KB bytecode limit without IR optimisation. Without it, deployment will revert with an out-of-gas error.

---

## Environment Setup

Copy the example environment file and fill in all values:

```bash
cp .env.example .env
```

### `.env` Reference

```bash
# ── Deployer ──────────────────────────────────────────────────────────
DEPLOYER_ADDRESS=            # your wallet address (must match Imported wallet)

# ── Network ───────────────────────────────────────────────────────────
BASE_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=           # Basescan API key for verification

# ── Token ─────────────────────────────────────────────────────────────
MAX_SUPPLY=50000000000000000000000000    # 50 000 000e18

# ── Timelock ──────────────────────────────────────────────────────────
MIN_DELAY=60                 # 60s testnet | 172800 (2 days) mainnet

# ── Protocol ──────────────────────────────────────────────────────────
PROTOCOL_FEE=1500            # 15% (basis points)
LIQUIDATION_BONUS=800        # 8%  (basis points)

# ── Assets ────────────────────────────────────────────────────────────
# mWBTC
mWBTC_ADDRESS=
mWBTC_CHAINLINK_FEED=0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298
mWBTC_HEARTBEAT=86400
mWBTC_LTV=7000                # 70%
mWBTC_LT=7500                 # 75%
mWBTC_INTEREST_RATE=300                # 3% APR
mWBTC_DECIMALS=8

# mDAI
mDAI_ADDRESS=
mDAI_CHAINLINK_FEED=0xD1092a65338d049DB68D7Be6bD89d17a0929945e
mDAI_HEARTBEAT=86400
mDAI_LTV=7500                 # 75%
mDAI_LT=8000                  # 80%
mDAI_INTEREST_RATE=600                 # 6% APR
mDAI_DECIMALS=18

# mLINK
mLINK_ADDRESS=
mLINK_CHAINLINK_FEED=0xb113F5A928BCfF189C998ab20d753a47F9dE5A61
mLINK_HEARTBEAT=86400
mLINK_LTV=5000                # 50%
mLINK_LT=6500                 # 65%
mLINK_INTEREST_RATE=400                # 4% APR
mLINK_DECIMALS=18

# mUSDC
mUSDC_ADDRESS=
mUSDC_CHAINLINK_FEED=0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165
mUSDC_HEARTBEAT=86400
mUSDC_LTV=7500                # 75%
mUSDC_LT=8000                 # 80%
mUSDC_INTEREST_RATE=600                # 6% APR
mUSDC_DECIMALS=6

# mWETH
mWETH_ADDRESS=
mWETH_CHAINLINK_FEED=0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1
mWETH_HEARTBEAT=86400
mWETH_LTV=8000                # 80%
mWETH_LT=8500                 # 85%
mWETH_INTEREST_RATE=500                # 5% APR
mWETH_DECIMALS=18

# mUSDT
mUSDT_ADDRESS=
mUSDT_CHAINLINK_FEED=0x3ec8593F930EA45ea58c968260e6e9FF53FC934f
mUSDT_HEARTBEAT=86400
mUSDT_LTV=7500                # 75%
mUSDT_LT=8000                 # 80%
mUSDT_INTEREST_RATE=600                # 6% APR
mUSDT_DECIMALS=6
```

> **Important:** The `DECIMALS` values must match the **token contract's decimals**, not the Chainlink oracle decimals. Chainlink always returns 8-decimal prices regardless of the asset. The `1e10` bridge factor in `_getAssetValueUSD` handles the conversion internally.

---

## Running Tests

### Unit Tests

```bash
# Run all unit tests
forge test --mc ArgentProtocolTest -vv

# Run a specific test
forge test --mt testRepayFullRepayClearsDebt -vvv

# Run with gas reporting
forge test --mc ArgentProtocolTest --gas-report
```

### Invariant Tests

```bash
# Run all invariant tests (512 runs × 64 depth)
forge test --mc ArgentProtocolInvariantTest -vv

# Run a single invariant
forge test --mt invariant_01_realBalanceCoversAllLiabilities -vvv
```

### Invariant Configuration (`foundry.toml`)

```toml
[invariant]
runs            = 512
depth           = 64
fail_on_revert  = true
```

### Test Coverage

```bash
forge coverage --mc ArgentProtocolTest
```

### Test Architecture

```
test/
├── unit/
│   ├── ArgentProtocolTest.t.sol          # ~128 unit tests, >98% coverage
|   ├── ArgentumTest.t.sol                # ~12 unit tests, 100% coverage
|   ├── DeployArgentProtocolTest.t.sol    # ~15 unit tests, >97% coverage
|   ├── PriceOracleTest.t.sol             # ~11 unit tests, >96% coverage
|   ├── SenateTest.t.sol                  # ~5 unit tests, 100% coverage
|   └── TreasuryTest.t.sol                # ~12 unit tests, 100% coverage
├── invariant/
│   ├── ArgentProtocolInvariantTest.t.sol   # 12 stateful invariants
│   └── ArgentHandler.sol                   # Bounded action handler
└── mocks/
    ├── MockERC20.sol
    ├── MockERC20Votes.sol
    ├── MockPriceOracle.sol
    └── RevertingMockFeed.sol
```

#### Invariant Severity Levels

| Invariant | Severity | What It Verifies |
|-----------|----------|-----------------|
| `invariant_01_realBalanceCoversAllLiabilities` | **CRITICAL** | Real token balance ≥ net depositor obligations |
| `invariant_02_borrowExcessLeadsToZeroAvailableLiquidity` | **CRITICAL** | When borrows exceed pool, available liquidity = 0 |
| `invariant_03_availableLiquidityBoundedAndNonNegative` | **CRITICAL** | Available liquidity never overflows or wraps |
| `invariant_04_ghostCollateralUpperBoundsTotalDeposits` | **HIGH** | No collateral created from nothing |
| `invariant_05_ghostLiquidityExactlyMatchesTotalLiquidity` | **HIGH** | Liquidity accounting never drifts |
| `invariant_06_protocolFeesBoundedByTotalPool` | **HIGH** | Fees never exceed the entire deposit pool |
| `invariant_07_borrowIndexStrictlyNonDecreasing` | **HIGH** | Interest index only ever increases |
| `invariant_08_borrowIndexNeverFallsBelowInitialIndex` | **HIGH** | Index never falls below 1e18 |
| `invariant_09_lastAccrualTimestampNotInFuture` | **HIGH** | Accrual timestamp never in the future |
| `invariant_10_noUserCollateralExceedsTotalDeposits` | **HIGH** | No user has more collateral than the global total |
| `invariant_11_zeroDebtImpliesMaxHealthFactor` | **HIGH** | No debt = infinite health factor |
| `invariant_12_liquidatabilityConsistentWithHealthFactor` | **HIGH** | HF and liquidatable flag always agree |

---

## Deployment

### Deploy to Base Sepolia

```bash
# Dry run — simulate without broadcasting
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  -vvvv

# Live deployment with verification
forge script script/DeployArgentProtocol.s.sol:DeployArgentProtocol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --account account1 \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify \
  -vvvv
```

### Deployment Order

The script enforces this order automatically:

```
1. Treasury          ← no dependencies
2. Argentum          ← recipient = Treasury address (tokens land in governance custody)
3. ArgentTimelock    ← deployer as temporary proposer
4. Senate            ← needs Argentum + Timelock
5. PriceOracle       ← needs owner address
6. ArgentProtocol    ← needs Oracle + Treasury
   ↓
7. Set oracle feeds  ← one per asset
8. Register assets   ← addAsset() per asset
9. Wire DAO roles    ← Senate → PROPOSER + CANCELLER on Timelock
10. Transfer ownership ← all contracts → Timelock
```

---

## Security Analysis

### Slither

Static analysis was performed using [Slither](https://github.com/crytic/slither) by Trail of Bits.

```bash
# Install
python3 -m venv slither-env
source slither-env/bin/activate
pip install slither-analyzer

# Run (filtered for known OZ false positives)
slither . --filter-paths "openzeppelin" --exclude-low --exclude-informational
```

#### Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| ID-0 | Medium | Divide-before-multiply in `_getMaxLiquidatableDebt` | Acknowledged — single combined division minimises precision loss |
| ID-1 to ID-7 | Medium | Strict equality comparisons | Acknowledged — all are intentional guards, not manipulable by callers |
| ID-8, ID-9 | Medium | Uninitialized locals in `PriceOracle.getPrice` | **False positive** — variables assigned in `try` block; `catch` always reverts |
| ID-10 | Medium | Unused return value in `PriceOracle.getPrice` | **False positive** — `_answer` and `_updatedAt` are captured and validated |
| ID-11 | Low | Missing event for `setLiquidationBonus` | Fixed — `LiquidationBonusUpdated` event added |
| ID-12 to ID-20 | Low | External calls inside loops | Acknowledged — price oracle calls inside `userActiveAssets` loops; bounded by user asset count |
| ID-21 | Low | Reentrancy in `Treasury.transferETH` | Fixed — `ReentrancyGuard` added, event emitted before external call |
| ID-22 to ID-36 | Low | Timestamp comparisons | Acknowledged — post-merge validators can shift timestamps by ≤15s; negligible impact on hourly heartbeats and annual interest rates |
| ID-37 | Informational | Low-level call in `Treasury.transferETH` | Acknowledged — standard ETH transfer pattern; result checked |
| ID-38 | Informational | `PriceOracle` missing `IPriceOracle` inheritance | Fixed — interface extracted to `src/interfaces/IPriceOracle.sol` |

### Aderyn

Static analysis was performed using [Aderyn](https://github.com/Cyfrin/aderyn) by Cyfrin.

```bash
# Install
cargo install aderyn

# Run
aderyn . --output aderyn-report.md
```

#### Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| H-1 | High | `Treasury.transferETH` unprotected from ETH send | Fixed — balance check added, `nonReentrant` applied |
| L-1 | Low | Centralisation risk for trusted owners | Mitigated — all `onlyOwner` functions controlled by Timelock after deployment |
| L-2 | Low | Wide pragma `^0.8.20` | Acknowledged — lock to `0.8.20` before mainnet deployment |
| L-3 | Low | `public` functions that should be `external` | Partially fixed — OZ override functions must remain `public` |
| L-4 | Low | Magic literal values in math | Fixed — `PRICE_BRIDGE = 1e10` constant added |
| L-5 | Low | Events missing `indexed` fields | Fixed — `amount` indexed on financial events |
| L-6 | Low | PUSH0 not supported on all chains | Not applicable — Base Sepolia supports Shanghai EVM |
| L-7 | Low | Large literals should use scientific notation | Fixed — `BASIS_POINTS = 10_000` uses underscore separator |

---

## Governance

All protocol changes require a governance vote:

### Proposal Lifecycle

```
1. Any address with ≥ 500 ARG calls Senate.propose()
              ↓
2. Voting delay: ~1 day (7 200 blocks) — no votes accepted yet
              ↓
3. Voting period: ~1 week (50 400 blocks) — FOR / AGAINST / ABSTAIN
              ↓
4. Quorum check: ≥ 4% of total ARG supply must vote
              ↓
5. If passed: Senate.queue() sends to ArgentTimelock
              ↓
6. Timelock delay: 2 days (172 800 seconds on mainnet)
              ↓
7. Anyone calls Senate.execute() after delay expires
```

### Governable Actions

All of the following require a successful Senate vote:

- `ArgentProtocol.addAsset()` — list a new collateral asset
- `ArgentProtocol.setAssetStatus()` — freeze or deactivate an asset
- `ArgentProtocol.setProtocolFee()` — change the fee charged on interest
- `ArgentProtocol.setLiquidationBonus()` — change the liquidator incentive
- `ArgentProtocol.setTreasury()` — update the fee recipient address
- `ArgentProtocol.setPriceOracle()` — upgrade the oracle contract
- `ArgentProtocol.withdrawProtocolFees()` — move accumulated fees to treasury
- `PriceOracle.setPriceFeed()` — update or add a Chainlink feed
- `Treasury.transferERC20()` — move tokens from treasury
- `Treasury.transferETH()` — move ETH from treasury
- `Argentum.mint()` — issue new ARG tokens (up to MAX_SUPPLY)

---

## Protocol Parameters

### Interest Rate Model

Argent uses a **fixed interest rate** per asset set by governance. There is no utilisation curve. Rates are charged annually in basis points.

```
Accrued interest formula:
  interestFactor = (rate × timeDelta × 1e18) / (365 days × 10 000)
  newIndex       = oldIndex × (1e18 + interestFactor) / 1e18
  userDebt       = storedPrincipal × (currentIndex / userIndex)
```

### Health Factor

```
HF = (Σ collateralUSD × assetLiquidationThreshold) / (totalDebtUSD × 10 000)

HF ≥ 1e18  → healthy (no liquidation)
HF < 1e18  → liquidatable
HF = max   → no debt (infinite)
```

### Asset Parameters at Launch (Base Sepolia)

| Asset | LTV | Liq. Threshold | Interest Rate | Decimals |
|-------|-----|----------------|---------------|----------|
| mWBTC | 70% | 75% | 5% APR | 8 |
| mDAI  | 75% | 80% | 6% APR | 18 |
| mLINK | 50% | 65% | 4% APR | 18 |
| mUSDC | 75% | 80% | 6% APR | 6 |
| mWETH | 80% | 85% | 5% APR | 18 |
| mUSDT | 75% | 80% | 6% APR | 6 |

### Protocol Fees

| Parameter | Value |
|-----------|-------|
| Protocol fee | 15% of interest paid |
| Liquidation bonus | 8% of collateral seized |
| Max protocol fee cap | 50% |

---

## Known Limitations

### Lenders Do Not Yet Earn Yield

In the current version of Argent Protocol (V1), liquidity providers do not accrue interest or yield on supplied assets.

While borrowers are charged interest, the protocol currently routes those fees to protocol reserves / treasury accounting rather than distributing yield proportionally to depositors.

This design was intentional for the initial release in order to:

- simplify accounting logic,
- harden liquidation and solvency mechanics first,
- reduce attack surface during early development,
- and prioritize core lending functionality.

Future protocol versions may introduce:

- interest-bearing deposit tokens,
- dynamic utilization-based yield,
- reserve factor distribution,
- staking incentives,
- or vault-based liquidity accounting.


**Fixed interest rates** — unlike Aave or Compound, Argent does not use a utilisation-based rate curve. Rates may be uncompetitive during periods of high or low demand. Governance must monitor and adjust rates manually.

**No flash loan protection** — the protocol does not implement EIP-3156 flash loan hooks. Same-block price manipulation is partially mitigated by Chainlink's deviation thresholds and heartbeat staleness checks.

**L2 sequencer risk** — on Base (an L2), a sequencer outage could delay price updates. The PriceOracle does not implement an L2 sequencer uptime feed check (recommended for mainnet deployment). See [Chainlink L2 Sequencer Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds).

**Single oracle dependency** — prices rely entirely on Chainlink. Feed manipulation or failure reverts all price-sensitive operations. A TWAP fallback or secondary oracle is recommended for mainnet.

**`totalBorrows` includes capitalised interest** — when a partial repayment is made with accrued interest, `totalBorrows` is synced forward to include that interest. This means `totalBorrows` can temporarily exceed `totalDeposits + totalLiquidity`. `getAvailableLiquidity()` returns zero in this case, correctly preventing further borrows and withdrawals.

---

## Audit Notes

This protocol has not undergone a formal third-party audit. The following automated analyses were performed:

- **Slither** (Trail of Bits) — static analysis, full results in `slither-report.json`
- **Aderyn** (Cyfrin) — static analysis, full results in `aderyn-report.md`
- **Foundry Invariant Testing** — 12 stateful invariants across 512 runs × 64 depth each (393,216 total calls)

**This is a testnet deployment. Do not use with real funds.**

For mainnet deployment the following additional steps are recommended:

- Formal audit by a recognised smart contract security firm
- L2 sequencer uptime feed integration in PriceOracle
- Secondary oracle (TWAP) as fallback
- Bug bounty programme before TVL exceeds threshold
- Multisig as Timelock admin during initial launch period before full DAO handover

---

## License

MIT