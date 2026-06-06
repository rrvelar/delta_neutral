class OperationalSetting < ApplicationRecord
  belongs_to :updated_by, class_name: "User", optional: true

  validates :key, presence: true, uniqueness: true
  validates :value, presence: true
  validate :key_allowed
  validate :value_allowed

  private

  def key_allowed
    errors.add(:key, "is not allowed") unless OperationalSettings.allowed_key?(key)
  end

  def value_allowed
    errors.add(:value, "is invalid") unless OperationalSettings.valid_value_for_key?(key, value)
  end
end
