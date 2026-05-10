# Aerodrome Pre-Live Safety Audit

This is not approval to go live. It is a conservative status snapshot for the current read-only Aerodrome Slipstream work.

## Safety Status

| Item | Status | Notes |
| --- | --- | --- |
| Hyperliquid untouched | PASS | `HyperliquidService` is not modified by Aerodrome dry-run tooling. |
| Aerodrome read-only service | PASS | `AerodromeSlipstreamService` uses read-only `eth_call` paths. |
| Dry-run no DB writes | PASS | Dry-run returns reports and does not save records. |
| Dry-run no Hyperliquid | PASS | Dry-run does not instantiate or call `HyperliquidService`. |
| Config verification no DB writes | PASS | `aerodrome:verify_config` validates config and optional read-only RPC only. |
| Config verification no Hyperliquid | PASS | No Hyperliquid calls are used. |
| Pre-live readiness check | PASS | `aerodrome:pre_live_check` is read-only, performs no DB writes, places no orders, and only uses optional mocked/read-only `get_position("ETH")` when `CHECK_HYPERLIQUID=true`. |
| Live preflight check | PASS | `aerodrome:live_preflight_check` is read-only, requires live-mode env to remain disabled/paused during preflight, and never calls Hyperliquid execution methods. |
| Monitor-only sync disabled by default | PASS | `AERODROME_READ_ONLY_ENABLED=false` is the documented default. |
| HedgeSyncJob skips Aerodrome by default | PASS | `AERODROME_HEDGE_ENABLED=false` or missing skips Aerodrome before `HyperliquidService` construction. |
| Aerodrome kill switch | PASS | `AERODROME_HEDGE_PAUSED` defaults to true when missing. Testnet rehearsal requires explicitly setting `AERODROME_HEDGE_PAUSED=false`. |
| Aerodrome hedge-loop flag | PASS | `AERODROME_HEDGE_ENABLED=true` can only feed complete Aerodrome ETH/WETH-side data into the existing `HedgeSyncJob` path; no new Hyperliquid execution path is added. |
| Aerodrome testnet rehearsal gate | PASS | Testnet rehearsal still requires `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true`. |
| Aerodrome live approval gate | PASS | Hyperliquid mainnet Aerodrome hedge processing skips before `HyperliquidService` unless `AERODROME_LIVE_APPROVED=true`; this flag is not enough by itself. |
| First live micro-run runbook | PASS | `docs/AERODROME_FIRST_LIVE_MICRO_RUN.md` is documentation only. It adds no live task, no order path, no env changes, and requires a separate tested live emergency close procedure before any live micro-run. |
| Aerodrome max short ETH | PASS | Optional `AERODROME_MAX_SHORT_ETH` blocks the ETH/WETH side before the order path when target short exceeds the configured value. |
| Aerodrome max notional | PASS | Optional `AERODROME_MAX_SHORT_NOTIONAL_USD` blocks the ETH/WETH side before the order path when target notional exceeds the configured value. |
| Aerodrome max leverage | PASS | Optional `AERODROME_MAX_LEVERAGE` blocks before the order path when `Setting.hyperliquid_leverage` exceeds the configured value; the app does not silently change leverage. |
| Aerodrome USDC hedge exclusion | PASS | The Aerodrome gate skips USDC and unsupported symbols before `check_and_rebalance`, so the stablecoin side is never hedged. |
| Aerodrome testnet open rehearsal | PASS | A tiny WETH/ETH-side testnet short opened successfully; this is not live approval. |
| Aerodrome same-size rebalance skip | PASS | 10h testnet soak found successful WETH rows where rounded `old_short_size == new_short_size`; rounded same-size targets now skip order submission and `ShortRebalance` creation. |
| Aerodrome delta-only rebalance | PASS | 10h testnet soak showed full close/open churn; rebalances now adjust only the delta between current and target short sizes. |
| Aerodrome minimum delta notional | PASS | 1h delta-only soak showed tiny deltas below Hyperliquid minimum order notional; Aerodrome now skips sub-minimum non-close deltas without creating failed rows. |
| Aerodrome close-to-zero bypass | PASS | Close-to-zero bypasses the failed-rebalance circuit breaker so cleanup closes are still attempted after prior small-delta failures. |
| Aerodrome testnet emergency close | PASS | Testnet-only emergency close task retries ETH close/readback after transient Hyperliquid testnet API/DNS failures and refuses live-approved/mainnet contexts. |
| Aerodrome testnet close-path rehearsal | BLOCKED PENDING RETEST | The close path exposed a false-success bug, then an SSL ambiguity during explicit close. `HedgeSyncJob` now reconciles ambiguous open/close errors by fetching actual Hyperliquid position state before recording success or failure. Live remains blocked until open and close reconciliation retests pass on testnet. |
| Amount0/amount1 implemented | PASS | Verified amount math is implemented for read-only service, dry-run, and monitor-only sync. |
| USDC-pool valuation preview | PASS | Supported only when one token matches configured `AERODROME_USDC_ADDRESS`; unsupported pairs keep prices nil. |
| Aerodrome read-only PnL snapshots | PASS | `PositionSyncJob` can create Aerodrome `PnlSnapshot` rows from persisted amounts and USD prices only. Fees and hedge PnL remain zero; no Hyperliquid execution methods are called. |
| Aerodrome dashboard hedge status | PASS | Position show displays a read-only Aerodrome hedge status card from local `Hedge` and `ShortRebalance` records. It does not query Hyperliquid actual short state and does not expose execution controls. |
| Aerodrome AERO rewards discovery | PASS | `aerodrome:rewards_check` is read-only, sends no claims/transactions, and reports gauge/reward availability without adding rewards to Total PnL. |
| WETH/USDC hedge preview | PASS | Preview-only calculation; `execution_enabled=false`, no orders, no Hyperliquid calls. |
| Manual hedge proposals | PASS | Local records only; create/review/reject/regenerate actions do not call Hyperliquid, do not place orders, and do not create executable `Hedge` records. |
| Proposal history/status | PASS | Recent proposal history and current/stale status are display-only and computed from local proposal and position records. |
| Proposal safety limits | PASS | Optional env-configured local checks can mark proposals `PASSED`, `WARNINGS`, or `BLOCKED`; blocked proposals cannot be marked reviewed. |
| UI monitor-only display | PASS | Dashboard/position views label Aerodrome as monitor-only and show no order execution controls. |
| USD valuation for non-USDC pairs | UNKNOWN | No trusted external USD valuation source is implemented. |
| Advanced fees deferred | UNKNOWN | Only raw owed-token fields are safe first reads. |
| Staking/gauge discovery unresolved | UNKNOWN | User-provided token ids remain the conservative starting point. |
| Manager/factory multi-deployment risk | UNKNOWN | Multiple deployments exist; config remains explicit. |
| Tests mock RPC | PASS | Tests use mocks/WebMock for Aerodrome RPC behavior. |
| No real RPC in tests | PASS | No tests require internet or live Base RPC. |
| No `.env` committed | PASS | `.env` remains untouched. |
| No private keys | PASS | Dry-run/config verification do not require private keys. |
| Live order placement | PASS | No Aerodrome path places orders. |
| Approvals/transfers/swaps/NFT transfers | PASS | No write transaction paths are implemented. |

## Recommendation

NOT READY FOR LIVE HEDGE INTEGRATION.

READY ONLY FOR READ-ONLY MANUAL DRY-RUN AND MONITOR-ONLY TESTING.

Manual hedge proposals are not execution approval. Proposal review/rejection only updates local status and timestamps and does not place orders. Safety limits are local proposal checks only. Missing limits are warnings. Blocked proposals must not be used for execution and cannot be marked reviewed. Stale proposals must be regenerated before any manual review. `AERODROME_HEDGE_ENABLED` remains false/default-off.

Aerodrome hedge-loop processing is feature-flagged and disabled by default. Testnet rehearsal requires `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true`. Hyperliquid mainnet Aerodrome hedge processing requires the separate hard approval flag `AERODROME_LIVE_APPROVED=true`, but that flag is not sufficient by itself: `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, complete readiness data, risk limits, and WETH/ETH-only filtering are still required. Production live must keep `AERODROME_HEDGE_ENABLED=false` and `AERODROME_HEDGE_PAUSED=true` until a separate future first-live procedure is approved. The Aerodrome path reuses the existing HyperliquidService-backed hedge loop unchanged, requires complete persisted position data, supports only ETH/WETH exposure, and skips USDC.

Aerodrome hedge execution is also paused by default through `AERODROME_HEDGE_PAUSED=true`. Missing `AERODROME_HEDGE_PAUSED` is treated as paused. To run any testnet rehearsal, the operator must explicitly set `AERODROME_HEDGE_PAUSED=false`; live trading is still not approved. Optional maximum short ETH, maximum short notional USD, and maximum leverage limits are local pre-order gates for the Aerodrome path only.

Aerodrome dashboard PnL snapshots are read-only. They use persisted Aerodrome amounts and supported USDC-quoted USD prices to calculate pool value movement against `entry_value_usd`. If the baseline is missing, the first compatible Aerodrome snapshot sets `entry_value_usd` to the current pool value. Aerodrome fees are not implemented yet and remain zero until a separate fee-read task; hedge PnL is also zero in these snapshots unless a separate read-only Hyperliquid snapshot task is added. This does not enable live trading or any order path.

The Aerodrome position dashboard now shows `entry_value_usd`, current pooled value, and pool delta from entry, plus an explanatory note that the PnL baseline starts from the first Aerodrome snapshot unless manually set. If an explicit `Hedge` exists, the dashboard shows target/tolerance, target ETH short, execution gate state, mode labels, and latest WETH/ETH rebalance from local records only. This hedge status card is read-only; actual ETH short readback is disabled by default, fees remain a future task, and live remains disabled.

AERO rewards are read-only discovery only. `bin/rails aerodrome:rewards_check` and the dashboard do not claim, approve, transfer, or send transactions. When `AERODROME_REWARDS_ENABLED=true`, the Aerodrome position page runs the same read-only check and displays status, staked state, claimable AERO amount, AERO USD price/source when configured, claimable AERO USD estimate, depositor address/source, gauge address, and token id; config/RPC failures render as unavailable without breaking the page. For staked Slipstream NFTs, the stored/owner wallet can be the gauge, so set `AERODROME_REWARDS_DEPOSITOR_ADDRESS` to the real staking wallet to read earned rewards. When unset, the check falls back to `position.wallet.address`. It reports `position_wallet_address`, compatibility `wallet_address`, `depositor_address`, `depositor_source`, and `gauge_address`; `not_staked` means the token id was not found for that selected depositor in the discovered CL gauge. The dashboard shows Total PnL excluding AERO rewards and Total PnL including unclaimed AERO rewards estimate separately. Claiming and staking are not implemented; rewards are not realized until claimed/sold. AERO USD valuation requires a configured/verified price source. The verified Base AERO/USDC Slipstream CL pool for read-only valuation is `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1`; use `AERODROME_AERO_USD_VALUATION_ENABLED=true`, `AERODROME_AERO_USDC_POOL_ADDRESS=0xbe00ff35af70e8415d0eb605a286d8a45466a4c1`, and a blank `AERODROME_AERO_USD_MANUAL_PRICE` for on-chain readback, or keep the manual price fallback explicitly operator-managed. Live remains disabled.

Aerodrome LP fee discovery is read-only. `bin/rails aerodrome:fees_check` and the dashboard do not collect fees, approve, transfer, or send transactions. The dashboard only runs the fee check when `AERODROME_FEES_ENABLED=true`; otherwise it reports not configured/unavailable instead of fake zero. For unstaked positions, the verified read path is `NonfungiblePositionManager.positions(tokenId)` `tokensOwed0/tokensOwed1`, converted with token decimals and valued separately from realized PnL. If the NFT is staked in a CL gauge or staking status makes fee readback unsafe, the dashboard reports unavailable instead of fake zero. Unclaimed fees are estimates until collected; collecting fees is not implemented. Live remains disabled.

Testnet rehearsal found that the open path can submit a tiny WETH/ETH short, but the close path previously used SDK `market_close`, logged `No open position to close for ETH`, and still recorded a successful `ShortRebalance` with `new_short_size=0`. False successful close rebalances created before the close-path fix must not be trusted as evidence that a Hyperliquid short was closed. The close path now uses an explicit opposite market order with the known `current_short` size when `HedgeSyncJob` is closing to zero.

The explicit close retest then encountered `SSL_read: unexpected eof while reading`; the short remained open and the app correctly recorded failure. Similar SSL ambiguity can occur after open orders, where the order may execute even if the client receives a network exception. `HedgeSyncJob` now reconciles ambiguous post-order errors by fetching actual Hyperliquid position state and comparing the actual short size with the intended target before writing the final `ShortRebalance` status. Explicit API rejections remain failures. Live remains blocked until both open and close reconciliation retests pass on testnet.

A 10h Hyperliquid testnet soak found same-size WETH rebalance churn after Hyperliquid size rounding, such as `0.0116 -> 0.0116`. `HedgeSyncJob` now skips when the rounded `target_short` equals `current_short`, before any close/open/leverage calls or `ShortRebalance` creation. This reduces unnecessary fees, slippage, and API/order risk. Live remains disabled.

The same soak also showed unnecessary full close/open churn when only a size adjustment was needed. `HedgeSyncJob` now uses delta-only rebalancing: increases open only the additional short size, decreases close only the excess short size, and full close is reserved for `target_short == 0`. This reduces fees, slippage, and order/API risk. Live remains disabled.

A 1h delta-only soak showed most target changes produced tiny deltas below Hyperliquid's minimum order notional, creating failed `ShortRebalance` rows and eventually tripping the circuit breaker. Aerodrome non-close deltas below `AERODROME_MIN_ORDER_NOTIONAL_USD` now skip without order submission or failed rows. Missing `AERODROME_MIN_ORDER_NOTIONAL_USD` defaults to 10. Close-to-zero bypasses the failed-rebalance circuit breaker so final cleanup closes are still attempted and reconciled truthfully. Live remains disabled.

A later 1h Aerodrome testnet soak showed final close can still fail when Hyperliquid testnet DNS/API is unavailable, for example `getaddrinfo / api.hyperliquid-testnet.xyz`. The testnet-only `bin/rails aerodrome:testnet_emergency_close` task retries an explicit ETH close with readback and refuses to run unless `HYPERLIQUID_TESTNET=true` and `AERODROME_LIVE_APPROVED=false`. It never touches USDC. Live close/emergency procedures remain separate future work, and live remains disabled.

`bin/rails aerodrome:pre_live_check` and `FORMAT=json bin/rails aerodrome:pre_live_check` provide a read-only readiness report across environment safety, `AERODROME_LIVE_APPROVED` state, local DB readiness, configured risk limits, rehearsal `ShortRebalance` evidence, and optional Hyperliquid readback. Passing this check is not permission for live trading. Live remains disabled by default and requires a separate future approval/change and first-live procedure.

`bin/rails aerodrome:live_preflight_check` and `FORMAT=json bin/rails aerodrome:live_preflight_check` provide a stricter read-only first-live preflight for mainnet configuration. It requires `HYPERLIQUID_TESTNET=false` while `AERODROME_LIVE_APPROVED=false`, `AERODROME_HEDGE_ENABLED=false`, and `AERODROME_HEDGE_PAUSED=true`; optional `CHECK_HYPERLIQUID=true` performs read-only ETH position/account checks only. PASS is not permission to live trade. The first live micro-run and any live emergency close procedure must be separate manual future procedures, and live remains disabled by default.

`docs/AERODROME_FIRST_LIVE_MICRO_RUN.md` is a runbook only. It does not enable live trading and does not add an executable live command. Any first-live micro-run remains forbidden until preflight passes, no Hyperliquid mainnet ETH short exists, tiny operator-defined limits are set manually, and a separate live emergency close procedure exists and has been tested. Dashboard rewards and fees are read-only estimates and are not execution approval.

Do not enable Aerodrome hedge execution until amount math, USD valuation, hedge preview/proposal behavior, proposal history/staleness handling, proposal safety-limit operations, fee strategy, staking/gauge behavior, manager/factory coverage, and end-to-end comparisons against Aerodrome UI/BaseScan are complete and tested. Current valuation, hedge previews, safety checks, and manual proposals do not make Aerodrome positions hedge-ready.
