# Aerodrome Core PR1

PR1 adds the read-only Aerodrome Slipstream foundation for adapting the bot from Uniswap V3 LP positions to Aerodrome Slipstream LP positions on Base.

## Included

- `AerodromeSlipstreamMath` computes raw token amounts from Slipstream liquidity, ticks, and `sqrtPriceX96`.
- `AerodromeSlipstreamService` reads Aerodrome contracts through JSON-RPC `eth_call` only.
- The service supports `ownerOf(tokenId)`, `positions(tokenId)`, `factory()`, `WETH9()`, factory `getPool(token0, token1, tickSpacing)`, pool `slot0()`, and ERC20 metadata reads.
- Tests use mocked RPC responses only.

## Not Included

- No jobs are connected yet.
- No position sync changes are included yet.
- No hedge logic is connected yet.
- `HyperliquidService` is unchanged.
- No transactions, approvals, swaps, NFT transfers, private keys, or order execution are added.

## Next PR

PR2 should connect Aerodrome position sync using the read-only service while preserving existing Uniswap behavior.
