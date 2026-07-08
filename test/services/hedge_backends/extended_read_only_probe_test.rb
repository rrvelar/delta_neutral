require "test_helper"

module HedgeBackends
  class ExtendedReadOnlyProbeTest < ActiveSupport::TestCase
    # Real filled target-open order shape captured read-only from
    # GET /user/orders/2074738406414946304.
    def real_filled_open
      {
        "status" => "OK",
        "data" => {
          "id" => 2074738406414946304,
          "market" => "ETH-USD",
          "type" => "MARKET",
          "side" => "SELL",
          "status" => "FILLED",
          "qty" => "1.8160000000000000",
          "filledQty" => "1.8160000000000000",
          "cancelledQty" => "0.0000000000000000",
          "reduceOnly" => false,
          "timeInForce" => "IOC"
        }
      }
    end

    def probe_for(response)
      client = Class.new do
        define_method(:initialize) { |resp| @resp = resp }
        define_method(:order_by_id) { |_id| @resp }
      end.new(response)
      ExtendedReadOnlyProbe.new(env: {}, client: client)
    end

    test "normalizes a filled order and stringifies the big-integer id" do
      order = probe_for(real_filled_open).find_order("2074738406414946304")

      assert_equal "2074738406414946304", order[:id]
      assert_instance_of String, order[:id]
      assert_equal "FILLED", order[:status]
      assert_equal "ETH-USD", order[:market]
      assert_equal "SELL", order[:side]
      assert_equal "1.816", order[:qty_eth]
      assert_equal "1.816", order[:filled_eth]
      assert_equal "0.0", order[:remaining_eth]
      assert_equal false, order[:reduce_only]
    end

    test "derives remaining as qty minus filledQty" do
      partial = real_filled_open
      partial["data"] = partial["data"].merge("filledQty" => "1.0", "status" => "NEW")
      order = probe_for(partial).find_order("x")

      assert_equal "0.816", order[:remaining_eth]
    end

    test "returns nil when the envelope status is not OK" do
      assert_nil probe_for({ "status" => "ERROR", "message" => "not found" }).find_order("x")
    end

    test "returns nil on an HTTP error hash (404) from the client" do
      assert_nil probe_for({ "error" => "HTTP 404", "http_status" => 404 }).find_order("x")
    end

    test "returns nil and never raises when the client raises" do
      raising = Class.new { def order_by_id(_id) = raise("boom") }.new
      assert_nil ExtendedReadOnlyProbe.new(env: {}, client: raising).find_order("x")
    end

    test "returns nil for a blank order id without calling the client" do
      client = Class.new { def order_by_id(_id) = raise("should not be called") }.new
      assert_nil ExtendedReadOnlyProbe.new(env: {}, client: client).find_order("")
    end
  end
end
