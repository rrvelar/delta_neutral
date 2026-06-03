class RiskSetting < ApplicationRecord
  belongs_to :updated_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true
  validates :value, presence: true
  validate :key_allowed
  validate :value_allowed

  def numeric_value
    BigDecimal(value)
  rescue ArgumentError
    nil
  end

  private

  def key_allowed
    errors.add(:key, "is not allowed") unless RiskSettings.allowed_key?(key)
  end

  def value_allowed
    return unless RiskSettings.allowed_key?(key)

    errors.add(:value, "is invalid") unless RiskSettings.valid_value?(key, value)
  end
end
