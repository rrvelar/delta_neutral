class AddSourceAndMellowMetadataToPositions < ActiveRecord::Migration[8.1]
  def change
    add_column :positions, :source, :string
    add_column :positions, :mellow_metadata, :text
    add_index :positions, :source
  end
end
