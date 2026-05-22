module HedgeVenues
  DEFAULT = "hyperliquid".freeze
  KEYS = %w[hyperliquid ethereal nado].freeze
  LABELS = {
    "hyperliquid" => "Hyperliquid",
    "ethereal" => "Ethereal",
    "nado" => "Nado"
  }.freeze

  def self.normalize(value)
    key = value.to_s.downcase
    KEYS.include?(key) ? key : DEFAULT
  end

  def self.label(value)
    LABELS.fetch(normalize(value))
  end

  def self.options
    KEYS.map { |key| [ LABELS.fetch(key), key ] }
  end

  def self.build(name, **kwargs)
    case normalize(name)
    when "ethereal"
      Ethereal.new(**kwargs)
    when "nado"
      Nado.new(**kwargs)
    else
      Hyperliquid.new(**kwargs)
    end
  end
end
