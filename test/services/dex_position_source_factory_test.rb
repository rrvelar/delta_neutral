require "test_helper"

class DexPositionSourceFactoryTest < ActiveSupport::TestCase
  FakeUniswapService = Class.new do
    attr_reader :options

    def initialize(**options)
      @options = options
    end
  end

  FakeAerodromeService = Class.new do
    attr_reader :options

    def initialize(**options)
      @options = options
    end
  end

  test "default source is uniswap_v3" do
    without_env("DEX_POSITION_SOURCE") do
      factory = factory_with_doubles

      assert_equal "uniswap_v3", factory.source
      assert_instance_of FakeUniswapService, factory.build
    end
  end

  test "explicit uniswap_v3 builds UniswapService path" do
    source = factory_with_doubles(
      source: "uniswap_v3",
      uniswap_options: { subgraph_url: "https://subgraph.example", api_key: "test-key" }
    ).build

    assert_instance_of FakeUniswapService, source
    assert_equal({ subgraph_url: "https://subgraph.example", api_key: "test-key" }, source.options)
  end

  test "explicit aerodrome_slipstream builds AerodromeSlipstreamService path" do
    source = factory_with_doubles(
      source: "aerodrome_slipstream",
      aerodrome_options: {
        rpc_url: "https://base.example/rpc",
        position_manager_address: "0x0000000000000000000000000000000000000001",
        factory_address: "0x0000000000000000000000000000000000000002"
      }
    ).build

    assert_instance_of FakeAerodromeService, source
    assert_equal "https://base.example/rpc", source.options.fetch(:rpc_url)
  end

  test "unknown source raises clearly" do
    error = assert_raises(DexPositionSourceFactory::UnknownSourceError) do
      factory_with_doubles(source: "unknown").build
    end

    assert_match "Unknown DEX position source", error.message
    assert_match "unknown", error.message
  end

  test "missing Aerodrome config does not break default Uniswap selection" do
    without_env(
      "DEX_POSITION_SOURCE",
      "BASE_RPC_URL",
      "AERODROME_SLIPSTREAM_POSITION_MANAGER",
      "AERODROME_SLIPSTREAM_FACTORY"
    ) do
      assert_instance_of FakeUniswapService, factory_with_doubles.build
    end
  end

  test "missing Aerodrome config fails only when Aerodrome is selected" do
    without_env("BASE_RPC_URL", "AERODROME_SLIPSTREAM_POSITION_MANAGER", "AERODROME_SLIPSTREAM_FACTORY") do
      error = assert_raises(AerodromeSlipstreamService::ConfigError) do
        DexPositionSourceFactory.build(source: "aerodrome_slipstream")
      end

      assert_match "BASE_RPC_URL", error.message
    end
  end

  test "constructor source overrides env source" do
    with_env("DEX_POSITION_SOURCE" => "aerodrome_slipstream") do
      source = factory_with_doubles(source: "uniswap_v3").build

      assert_instance_of FakeUniswapService, source
    end
  end

  test "selecting Aerodrome does not call HyperliquidService" do
    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      source = DexPositionSourceFactory.build(
        source: "aerodrome_slipstream",
        aerodrome_options: {
          rpc_url: "https://base.example/rpc",
          position_manager_address: "0x0000000000000000000000000000000000000001",
          factory_address: "0x0000000000000000000000000000000000000002"
        }
      )

      assert_instance_of AerodromeSlipstreamService, source
    end
  end

  private

  def factory_with_doubles(**options)
    DexPositionSourceFactory.new(
      **{
        uniswap_service_class: FakeUniswapService,
        aerodrome_service_class: FakeAerodromeService
      }.merge(options)
    )
  end

  def without_env(*keys, &block)
    with_env(keys.to_h { |key| [ key, nil ] }, &block)
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
