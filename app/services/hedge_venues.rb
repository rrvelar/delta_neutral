module HedgeVenues
  DEFAULT = "nado".freeze
  SUPPORTED_KEYS = %w[nado ethereal extended].freeze
  LEGACY_KEYS = %w[hyperliquid].freeze
  KEYS = (LEGACY_KEYS + SUPPORTED_KEYS).freeze
  LABELS = {
    "hyperliquid" => "Hyperliquid",
    "ethereal" => "Ethereal",
    "nado" => "Nado",
    "extended" => "Extended"
  }.freeze

  def self.normalize(value)
    key = value.to_s.downcase
    KEYS.include?(key) ? key : DEFAULT
  end

  def self.known_key(value)
    key = value.to_s.downcase
    KEYS.include?(key) ? key : nil
  end

  def self.supported?(value)
    SUPPORTED_KEYS.include?(known_key(value))
  end

  def self.legacy?(value)
    LEGACY_KEYS.include?(known_key(value))
  end

  def self.default_supported(env: ENV)
    requested = env["DEFAULT_HEDGE_EXECUTION_VENUE"].to_s.downcase
    return requested if SUPPORTED_KEYS.include?(requested)

    configured = SUPPORTED_KEYS.find { |venue| configured?(venue, env: env) }
    configured || DEFAULT
  end

  def self.label(value)
    LABELS.fetch(normalize(value))
  end

  def self.options
    SUPPORTED_KEYS.map { |key| [ LABELS.fetch(key), key ] }
  end

  def self.options_with_legacy(value)
    selected = normalize(value)
    legacy?(selected) ? [ [ "Unsupported legacy venue: #{LABELS.fetch(selected)}", selected ] ] + options : options
  end

  def self.build(name, **kwargs)
    case normalize(name)
    when "ethereal"
      Ethereal.new(**kwargs)
    when "nado"
      Nado.new(**kwargs)
    when "extended"
      Extended.new(**kwargs)
    else
      Hyperliquid.new(**kwargs)
    end
  end

  def self.configured?(venue, env: ENV)
    case normalize(venue)
    when "nado"
      env.keys.any? { |key| key.start_with?("NADO_", "AERODROME_NADO_") }
    when "ethereal"
      env.keys.any? { |key| key.start_with?("ETHEREAL_", "AERODROME_ETHEREAL_") }
    when "extended"
      env.keys.any? { |key| key.start_with?("EXTENDED_") }
    else
      false
    end
  end
end
