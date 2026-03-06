# 🏠 EscrowRent

A secure, trustless rental escrow smart contract built on Ethereum. EscrowRent holds rent and deposit funds on-chain, releasing them automatically based on rental lifecycle events — with a neutral arbiter for dispute resolution.

**Deployed & Verified on Sepolia:**
[`0x7C358D26abbe4B68c10A3C801EE5F70e2d51f19B`](https://sepolia.etherscan.io/address/0x7c358d26abbe4b68c10a3c801ee5f70e2d51f19b)

---

## Overview

Traditional rental agreements rely on trust and legal systems. EscrowRent replaces that with code — the landlord, tenant, and an agreed arbiter interact with a smart contract that enforces every rule automatically.

```
Tenant funds → Contract holds → Rental period → Complete → Withdraw
                                      ↓
                                  Dispute?
                                      ↓
                              Arbiter resolves
```

---

## How It Works

| Step | Who | Action |
|------|-----|--------|
| 1 | Landlord | Deploys contract with tenant, arbiter, amounts, and dates |
| 2 | Tenant | Calls `fund()` with exact rent + deposit amount |
| 3 | Landlord | Calls `activate()` after start date |
| 4 | Either | Calls `complete()` after end date |
| 5 | Both | Call `withdraw()` to claim their funds |

If either party raises a dispute, the arbiter calls `resolveDispute()` to split funds. A 48-hour timelock protects against rushed resolutions.

---

## Contract Features

- **Exact funding** — tenant must send the precise rent + deposit amount, no partial fills
- **Activation grace period** — landlord has a window to activate; tenant can cancel if missed
- **Dispute window** — 3 days before rental end, either party can raise a dispute
- **Arbiter timeout** — if arbiter is unresponsive for 7 days, both parties can replace them via 2-of-2 consensus
- **Withdrawal timelock** — 48-hour delay after dispute resolution before funds can be withdrawn
- **Reentrancy protection** — all ETH transfers guarded by OpenZeppelin `ReentrancyGuard`

---

## Contract Roles

| Role | Address | Permissions |
|------|---------|-------------|
| Landlord | Deployer | `activate()`, `complete()`, `cancelIfUnactivated()`, `proposeNewArbiter()` |
| Tenant | Set at deploy | `fund()`, `complete()`, `raiseDispute()`, `proposeNewArbiter()` |
| Arbiter | Set at deploy | `resolveDispute()`, replaceable by 2-of-2 consensus |

---

## Security

This contract was developed with a security-first approach:

- **6 critical/high vulnerabilities** identified and patched
- **124 tests** — unit, integration, edge case, fuzz, security, and patch verification
- **Slither static analysis** — 0 actionable findings
- **Manual audit** — CEI pattern, access control, reentrancy, integer overflow, ETH lockup

### Patched Vulnerabilities

| # | Severity | Description |
|---|----------|-------------|
| 1 | Critical | Reentrancy in `withdraw()` via balance manipulation |
| 2 | Critical | Partial funding allowed griefing attacks |
| 3 | Critical | `complete()` blocked when contract in Disputed state |
| 4 | High | Dead arbiter — no replacement mechanism |
| 5 | High | Arbiter collusion — instant resolution without timelock |
| 6 | High | Short rental — dispute window exceeded rental duration |

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/)

### Install

```bash
git clone https://github.com/Abbaeth/rent-escrow.git
cd rent-escrow
forge install
```

### Run Tests

```bash
forge test -vvvv
```

```
Running 124 tests...
✅ 57  Unit tests
✅ 4   Integration tests
✅ 12  Edge case tests
✅ 8   Fuzz tests
✅ 6   Security tests
✅ 37  Patch verification tests
────────────────────────────────
✅ 124 passed | 0 failed
```

### Static Analysis

```bash
slither src/EscrowRent.sol
```

---

## Deployment

### 1. Set up environment

```bash
cp .env.example .env
# Fill in PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
```

### 2. Configure deployment parameters

Edit `script/Deploy.s.sol` and set:

```solidity
address constant TENANT_ADDRESS  = 0x...;
address constant ARBITER_ADDRESS = 0x...;
uint256 constant RENT_AMOUNT     = 0.1 ether;
uint256 constant DEPOSIT_AMOUNT  = 0.05 ether;
uint256 constant START_DATE      = 1234567890; // Unix timestamp
uint256 constant END_DATE        = 1234567890; // Unix timestamp
```

Generate timestamps:
```bash
date -d "2025-08-01" +%s   # Linux
```

### 3. Dry run

```bash
source .env
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv
```

### 4. Deploy & verify

```bash
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

---

## Project Structure

```
rent-escrow/
├── src/
│   └── EscrowRent.sol          # Main contract
├── test/
│   ├── EscrowRentBase.t.sol    # Shared test setup
│   ├── EscrowRent_Unit.t.sol   # Unit tests
│   ├── EscrowRent_Integration.t.sol
│   ├── EscrowRent_EdgeCases.t.sol
│   ├── EscrowRent_Fuzz.t.sol
│   ├── EscrowRent_Security.t.sol
│   └── EscrowRent_PatchVerification.t.sol
├── script/
│   └── Deploy.s.sol            # Deployment script
├── slither.config.json         # Static analysis config
├── foundry.toml
└── .env.example
```

---

## Contract Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `ACTIVATION_GRACE` | 3 days | Window for landlord to activate after start |
| `DISPUTE_WINDOW` | 3 days | Window before end date to raise dispute |
| `ARBITER_TIMEOUT` | 7 days | Days before arbiter can be replaced |
| `WITHDRAWAL_TIMELOCK` | 48 hours | Delay after dispute resolution |

---

## License

MIT
