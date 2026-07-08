module HedgeBackends
  # Read-only Extended order lookup for authoritative fast fill confirmation.
  # Wraps ExtendedApiClient#order_by_id (GET /user/orders/{order_id}, validated to
  # return completed/filled orders) and normalizes the {"status":"OK","data":{...}}
  # envelope. Never raises: returns nil on any error / not found / shape mismatch so
  # the caller fails closed to the slow position readback.
  class ExtendedReadOnlyProbe
    def initialize(env: ENV, client: nil)
      @env = env
      @client = client || ExtendedApiClient.new(env: env)
    end

    # Returns a normalized order hash or nil. `data.id` is stringified (the JSON
    # integer exceeds 2^53). remaining = qty - filledQty.
    def find_order(order_id)
      return nil if order_id.to_s.strip.empty?

      normalize(@client.order_by_id(order_id))
    rescue StandardError
      nil
    end

    private

    def normalize(body)
      return nil unless body.is_a?(Hash)
      return nil unless envelope_ok?(body)

      data = body["data"] || body[:data]
      return nil unless data.is_a?(Hash)

      qty = decimal_or_nil(data["qty"] || data[:qty])
      filled = decimal_or_nil(data["filledQty"] || data[:filledQty])
      cancelled = decimal_or_nil(data["cancelledQty"] || data[:cancelledQty])
      remaining = (qty - filled if qty && filled)
      {
        id: (data["id"] || data[:id]).to_s,
        status: data["status"] || data[:status],
        market: data["market"] || data[:market],
        side: data["side"] || data[:side],
        qty_eth: qty&.to_s("F"),
        filled_eth: filled&.to_s("F"),
        cancelled_eth: cancelled&.to_s("F"),
        remaining_eth: remaining&.to_s("F"),
        reduce_only: ActiveModel::Type::Boolean.new.cast(data.key?("reduceOnly") ? data["reduceOnly"] : data[:reduceOnly]),
        raw: data
      }
    end

    def envelope_ok?(body)
      (body["status"] || body[:status]).to_s.upcase == "OK"
    end

    def decimal_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
