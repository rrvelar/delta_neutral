class CreateOperationalSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :operational_settings do |t|
      t.string :key, null: false
      t.string :value, null: false
      t.text :reason
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_index :operational_settings, :key, unique: true

    create_table :operational_setting_audits do |t|
      t.string :key, null: false
      t.string :old_value
      t.string :new_value, null: false
      t.text :reason
      t.references :updated_by, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_index :operational_setting_audits, :key
  end
end
