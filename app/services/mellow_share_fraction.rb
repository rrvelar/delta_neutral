class MellowShareFraction
  Result = Data.define(:raw_value, :fraction, :interpretation, :exposure_fraction, :warnings)

  def self.resolve(value, metadata = {})
    new(value, metadata).resolve
  end

  def initialize(value, metadata = {})
    @value = value
    @metadata = metadata || {}
    @warnings = []
  end

  def resolve
    raw = BigDecimal(@value.to_s)
    exposure = exposure_fraction
    interpretation = interpretation_for(raw, exposure)
    fraction = interpretation == "fraction" ? raw : raw / 100
    warn_if_exposure_conflicts(fraction, exposure)

    Result.new(
      raw_value: raw,
      fraction: fraction,
      interpretation: interpretation,
      exposure_fraction: exposure,
      warnings: @warnings
    )
  rescue ArgumentError
    nil
  end

  private

  def interpretation_for(raw, exposure)
    return "percent" if raw > 1
    return "fraction" if close?(raw, exposure)
    return "percent" if close?(raw / 100, exposure)

    "percent"
  end

  def exposure_fraction
    candidates = []
    candidates << ratio(@metadata["user_weth_exposure"], @metadata["strategy_total_weth"])
    candidates << ratio(@metadata["user_usdc_exposure"], @metadata["strategy_total_usdc"])
    candidates.compact!
    return nil if candidates.empty?

    candidates.sum / candidates.size
  end

  def ratio(user_value, total_value)
    user = BigDecimal(user_value.to_s)
    total = BigDecimal(total_value.to_s)
    return nil unless total.positive?

    user / total
  rescue ArgumentError
    nil
  end

  def warn_if_exposure_conflicts(fraction, exposure)
    return unless exposure
    return if close?(fraction, exposure, tolerance: BigDecimal("0.05"))

    @warnings << "Mellow metadata share conflicts with exposure-derived share; rewards estimate is unverified."
  end

  def close?(left, right, tolerance: BigDecimal("0.000001"))
    return false unless left && right

    denominator = [ left.abs, right.abs, BigDecimal("1") ].max
    ((left - right).abs / denominator) <= tolerance
  end
end
