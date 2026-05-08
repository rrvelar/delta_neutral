# Aerodrome Core PR3

PR3 adds minimal USD valuation for Aerodrome Slipstream positions.

## Included

- Valuation supports only pools that include the configured `AERODROME_USDC_ADDRESS`.
- USDC is valued at 1 USD.
- The other token price is derived from pool `sqrtPriceX96` and token decimals using `BigDecimal`.
- Unsupported pairs or missing USDC config return unsupported valuation and leave prices nil.
- Wallet and position sync persist Aerodrome USD prices only when valuation is supported.

## Not Included

- No hedge execution.
- No UI changes.
- No controllers, migrations, proposal workflow, dry-run tooling, or operator runbooks.
- No `HyperliquidService` or `UniswapService` changes.

## Next PR

PR4 can add a disabled-by-default Aerodrome hedge gate using the existing hedge path.
