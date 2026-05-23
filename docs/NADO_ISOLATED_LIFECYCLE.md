# Nado Isolated 1x Hedge Lifecycle

This document records the no-live implementation evidence used by `delta_neutral` for Nado isolated ETH-PERP hedging.

## Source of Truth Checked

- `/Users/aleksandr/Apps/perp-hedge-research-bot/src/execution/adapters/nado.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/src/execution/eip712.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/src/execution/leverage_verification.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/scripts/dry_run_nado_isolated_close.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/scripts/execute_nado_isolated_leverage_verification.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/scripts/check_nado_high_notional_close_payloads.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/tests/test_execution_layer.py`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/tests/fixtures/nado_ui_market_close_position_sanitized.json`
- `/Users/aleksandr/Apps/perp-hedge-research-bot/docs/OPERATIONS_RUNBOOK.md`

## Action Semantics

| Action | Sender | Amount sign | Side | Reduce-only | Isolated bit | Order bits | Isolated margin high bits | Appendix | Expiration | Body | Readback truth |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| isolated open short | configured Nado subaccount | negative | sell | false | true | IOC | 1x notional margin x6 | high bits + 769 | seconds | `place_orders` batch | ETH-PERP isolated short near target |
| isolated increase | configured Nado subaccount | negative delta | sell | false | true | IOC | 1x delta notional margin x6 | high bits + 769 | seconds | `place_orders` batch | ETH-PERP isolated short near target |
| isolated partial reduce | not proven | positive delta candidate | buy | true | true candidate | IOC | unknown | unknown | unknown | unknown | no sibling fixture/test proves accepted partial reduce |
| bot isolated full close | configured Nado subaccount | positive full size | buy | true | true | IOC | current isolated margin x6 | high bits + 2817 | seconds | `place_orders` batch | locally valid, can fail Nado health with `2006` |
| UI-equivalent full close | default_1 sender from account address | positive full size | buy | true | true | IOC | omitted / zero | `2817` | milliseconds | `place_orders` batch | captured UI fixture shows accepted close |
| close/reopen fallback | close leg above, then open leg | buy full, then sell target | buy/sell | true/false | true | IOC | close zero, open 1x target margin | `2817`, then high bits + 769 | ms close, seconds open | two `place_orders` batches | close success requires flat, reopen success requires target short |

## Production Failure Root Causes

| Failure | Bad payload class | Root cause |
| --- | --- | --- |
| `Reduce only order increases position` | reduce-only buy with appendix not targeting isolated position correctly | The early close/reduce payload decoded as non-isolated (`appendix=2561`), so Nado evaluated it against the wrong account state. |
| `2081 An isolated subaccount cannot place order` | order sender was copied from isolated position readback | Nado place_orders must be submitted by the configured/default account sender; isolated position subaccount is readback metadata, not an order sender. |
| `2006 Insufficient account health` | locally valid bot isolated reduce-only close with current isolated margin high bits | Sibling diagnostics document this risk: isolated reduce-only close payloads can pass local checks and still fail exchange health. Captured UI close omits high bits and uses appendix `2817`. |

## Partial Reduce Status

No inspected sibling file contains a proven accepted partial isolated reduce fixture or live receipt. The sibling repo includes split-reduce diagnostics, but split reduce is disabled by default and is not promoted as proven. Therefore `delta_neutral` does not claim partial isolated reduce support.

Normal target decreases use the explicit `isolated_full_close_then_reopen` strategy. In Rails this is selected by `AERODROME_NADO_ISOLATED_DECREASE_STRATEGY=close_reopen`, which is also the code default. Setting the strategy to `delta_reduce` blocks before submit because partial isolated delta reduce is not exchange-proven.

1. Submit a UI-equivalent full close using appendix `2817`.
2. Poll bounded readback until ETH-PERP is flat.
3. Submit a fresh isolated 1x target-size short.
4. Mark success only after readback confirms target short.

If close readback is delayed beyond the bounded polling window, no reopen is submitted. A later resume operation may reopen target size only if fresh readback is flat.
