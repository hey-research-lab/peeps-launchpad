# Bonding → Uniswap V4 (new stack)

Real bonding → real V4 migrate, with **Instant-aligned fees + referrals** and Instant-style token tax.

## Contracts

| File | Role |
| --- | --- |
| `PeepsBondingV4Token.sol` | Clean fixed-supply token |
| `PeepsBondingV4TaxStore.sol` | Instant tax config at create |
| `PeepsBondingV4Factory.sol` | Create + curve; tax + referral plan bind |
| `PeepsBondingV4Router.sol` | Create/trade; tax on curve; auto-sweep protocol fees; auto-grad |
| `PeepsBondingFeeSink.sol` | Curve protocol 30% → WETH → `PeepsProtocolFeeRouter` |
| `PeepsBondingV4Migrator.sol` | Graduate → Instant tax hook pool → mint into Instant V4 LP vault |

## Fees (Instant parity)

| Stage | Split |
| --- | --- |
| Launch | 0.00025 ETH → fee router |
| Curve trade | **1%** = 0.70% creator + 0.30% protocol → fee router |
| Peeps swap fee (curve) | **0.25%** on bonding router (same as aggregator; ref `claimReferralEth`) |
| Post-grad LP | **70/30** via Instant `PeepsV4LPFeeVault` → fee router |
| Token tax | Creator-set 1%–10% on curve + post-migrate hook |
| Tax dividends | Instant `PeepsV4DividendDistributor` **pre-grad** (`claim`) |
| Tax liquidity | Virtual LP on curve (non-sellable) → minted into Uni LP at graduate |
| Aggregator swaps | 0.25% (+ 0.05% referrer when bound) |

## Referrals

Create accepts `specialCodeHash` (wins) or Normal `referrer`. Factory must be authorized:

`PeepsProtocolFeeRouter.setPlanFactory(bondingFactory, true)` (or `setBondingFactory`).

Claims: creator curve ETH + vault LP; referrer/platform via `PeepsProtocolFeeRouter.claim` / aggregator `claimReferralEth`.

## Deploy wiring

1. Deploy `PeepsBondingFeeSink(weth, feeRouter)` → factory `treasury`  
2. TaxStore → factory → `taxStore.setFactory`  
3. Router → `factory.setPeepsRouter` / `taxStore.setRouter`  
4. Migrator with Instant `PeepsV4LPFeeVault` as `vault`  
5. `factory.setFeeRouter(feeRouter)` + fee router `setPlanFactory`  
6. Instant registry `setBondingMigrator(migrator)`  
7. Instant vault `setBondingFactory(bondingFactory)` + `setProtocolFeeRecipient(feeRouter)`  
8. `factory.setProtocolFeeRecipient(feeRouter)` for launch fee  
