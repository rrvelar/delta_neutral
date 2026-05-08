# Builds the configured LP position source service without changing job routing.
#
# The default remains Uniswap V3. Aerodrome Slipstream is only constructed when
# explicitly selected, so missing Aerodrome config cannot break existing flows.
class DexPositionSourceFactory
  class UnknownSourceError < StandardError; end

  DEFAULT_SOURCE = "uniswap_v3"
  UNISWAP_V3 = "uniswap_v3"
  AERODROME_SLIPSTREAM = "aerodrome_slipstream"
  SUPPORTED_SOURCES = [ UNISWAP_V3, AERODROME_SLIPSTREAM ].freeze

  attr_reader :source

  def self.build(...)
    new(...).build
  end

  def initialize(
    source: nil,
    uniswap_options: {},
    aerodrome_options: {},
    uniswap_service_class: UniswapService,
    aerodrome_service_class: AerodromeSlipstreamService
  )
    @source = normalize_source(source.presence || ENV["DEX_POSITION_SOURCE"].presence || DEFAULT_SOURCE)
    @uniswap_options = uniswap_options
    @aerodrome_options = aerodrome_options
    @uniswap_service_class = uniswap_service_class
    @aerodrome_service_class = aerodrome_service_class
  end

  def build
    case source
    when UNISWAP_V3
      @uniswap_service_class.new(**@uniswap_options)
    when AERODROME_SLIPSTREAM
      @aerodrome_service_class.new(**@aerodrome_options)
    else
      raise UnknownSourceError, "Unknown DEX position source: #{source.inspect}"
    end
  end

  private

  def normalize_source(value)
    source = value.to_s.strip.downcase
    return source if SUPPORTED_SOURCES.include?(source)

    raise UnknownSourceError, "Unknown DEX position source: #{value.inspect}"
  end
end
