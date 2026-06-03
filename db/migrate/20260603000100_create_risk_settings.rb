class CreateRiskSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :risk_settings do |t|
      t.string :key, null: false
      t.string :value, null: false
      t.references :updated_by, foreign_key: { to_table: :users }
      t.text :reason
      t.timestamps
    end

    add_index :risk_settings, :key, unique: true

    create_table :risk_setting_audits do |t|
      t.string :key, null: false
      t.string :old_value
      t.string :new_value, null: false
      t.references :updated_by, foreign_key: { to_table: :users }
      t.text :reason
      t.timestamps
    end

    add_index :risk_setting_audits, :key
  end
end
