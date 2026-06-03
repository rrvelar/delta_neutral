class OperationalSettingAudit < ApplicationRecord
  belongs_to :updated_by, class_name: "User", optional: true
end
