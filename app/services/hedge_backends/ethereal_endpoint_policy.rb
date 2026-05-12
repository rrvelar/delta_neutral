module HedgeBackends
  class EtherealEndpointPolicy
    PUBLIC_READ_ONLY = {
      "GET /v1/product" => "Product metadata and precision fields",
      "GET /v1/product/{id}" => "Single product metadata",
      "GET /v1/product/market-price" => "Product oracle/bid/ask prices",
      "GET /v1/product/market-liquidity" => "Public market liquidity",
      "GET /v1/funding" => "Public funding history",
      "GET /v1/funding/projected" => "Projected funding",
      "GET /v1/funding/projected-rate" => "Projected funding rate",
      "GET /v1/rate-limit/config" => "Rate-limit configuration",
      "GET /v1/rpc/config" => "EIP-712 domain data for signing reference",
      "GET /v1/time" => "Server time",
      "GET /v1/maintenance" => "Maintenance status"
    }.freeze

    PRIVATE_READ_ONLY_CANDIDATE = {
      "GET /v1/subaccount" => "Subaccounts for account",
      "GET /v1/subaccount/all" => "All subaccounts",
      "GET /v1/subaccount/{id}" => "Subaccount by id",
      "GET /v1/subaccount/balance" => "Subaccount balances",
      "GET /v1/position" => "Positions by subaccount",
      "GET /v1/position/active" => "Active position by subaccount/product",
      "GET /v1/position/{id}" => "Position by id",
      "GET /v1/position/fill" => "Position fills",
      "GET /v1/position/liquidation" => "Position liquidation records",
      "GET /v1/order" => "Order history by subaccount",
      "GET /v1/order/{id}" => "Order status by id",
      "GET /v1/order/{id}/group" => "Order group",
      "GET /v1/order/fill" => "Order fills",
      "GET /v1/order/trade" => "Order trades",
      "GET /v1/linked-signer" => "Linked signers",
      "GET /v1/linked-signer/{id}" => "Linked signer by id",
      "GET /v1/linked-signer/address/{address}" => "Linked signer by address",
      "GET /v1/linked-signer/quota" => "Signer quota",
      "GET /v1/token" => "Tokens",
      "GET /v1/token/{id}" => "Token by id",
      "GET /v1/token/transfer" => "Token transfer history",
      "GET /v1/token/withdraw" => "Token withdrawal history"
    }.freeze

    DANGEROUS_EXECUTION = {
      "POST /v1/order" => "Place an order",
      "POST /v1/order/dry-run" => "Order simulation still exercises order payload semantics",
      "POST /v1/order/cancel" => "Cancel orders",
      "POST /v1/linked-signer/link" => "Link a signer",
      "POST /v1/linked-signer/refresh" => "Refresh linked signer",
      "POST /v1/linked-signer/extend" => "Extend linked signer",
      "DELETE /v1/linked-signer/revoke" => "Revoke linked signer",
      "POST /v1/token/{id}/withdraw" => "Withdraw token",
      "POST /v1/referral/claim" => "Claim referral rewards",
      "POST /v1/referral/activate" => "Activate referral",
      "POST /v1/time" => "Non-read GET alternative exists; mutation semantics unknown"
    }.freeze

    UNKNOWN = {
      "GET /v1/whitelist" => "Not relevant to hedge backend yet",
      "GET /v1/points" => "Rewards/points surface, not hedge backend",
      "GET /v1/points/summary" => "Rewards/points surface, not hedge backend",
      "GET /v1/points/total" => "Rewards/points surface, not hedge backend",
      "GET /v1/referral" => "Referral surface, not hedge backend",
      "GET /v1/referral/code/{code}" => "Referral surface, not hedge backend",
      "GET /v1/referral/summary" => "Referral surface, not hedge backend"
    }.freeze

    READ_ONLY_PROBE_ENDPOINTS = [
      "GET /v1/product",
      "GET /v1/product/market-price",
      "GET /v1/position/active",
      "GET /v1/subaccount/balance"
    ].freeze

    def self.category(endpoint)
      return :public_read_only if PUBLIC_READ_ONLY.key?(endpoint)
      return :private_read_only_candidate if PRIVATE_READ_ONLY_CANDIDATE.key?(endpoint)
      return :dangerous_execution if DANGEROUS_EXECUTION.key?(endpoint)
      return :unknown if UNKNOWN.key?(endpoint)

      :unknown
    end

    def self.read_only_probe_endpoint?(endpoint)
      READ_ONLY_PROBE_ENDPOINTS.include?(endpoint)
    end

    def self.dangerous?(endpoint)
      category(endpoint) == :dangerous_execution
    end
  end
end
