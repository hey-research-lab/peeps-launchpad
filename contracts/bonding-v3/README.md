# Bonding → Uniswap V3 (new stack)

Scanner-aware bonding curve launch. Reuses proven curve math (`../legacy-curve/PeepsBondingCurve.sol`) with a **new migrator**.

## Contracts

| File | Role |
| --- | --- |
| `PeepsBondingV3Token.sol` | Ownerless ERC-20 + permit; no mint/burn/tax/freeze/blacklist |
| `PeepsBondingV3Factory.sol` | Create path; deferred pool; Instant fees + referral bind |
| `PeepsBondingV3Router.sol` | Create / buy / sell / auto-sweep / auto-graduate |
| `PeepsBondingV3Migrator.sol` | Graduate: create pool at target → mint locked LP; **no arb Swap** |
| `PeepsBondingV3LPFeeVault.sol` | Locked LP NFT; 70/30 → fee router |

## Fees (Instant parity)

See [`config/bonding-fees.json`](../../config/bonding-fees.json).

| Fee | Bonding V3 | Instant V3/V4 |
| --- | --- | --- |
| Create / launch | **0.00025 ETH** → fee router | same |
| Curve trade | **1%** (70/30) **+ 0.25%** Peeps fee (ref 0.05%/platform 0.20%) | n/a on Instant create |
| Pool LP tier | 1% | 1% |
| LP fee share | **70/30** → fee router (referrals) | Instant locker 70/30 |
| Post-grad Peeps swap | 0.25% (+ referral 0.05%) | same |

Deploy: factory `treasury = PeepsBondingFeeSink`, `setFeeRouter`, fee router `setPlanFactory`, vault `setProtocolFeeRecipient`.
