class AddApplicationKeyToCustomers < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :application_key, :string
    add_index :customers, :application_key
  end
end
