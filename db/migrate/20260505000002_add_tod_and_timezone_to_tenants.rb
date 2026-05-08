class AddTodAndTimezoneToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :tod_morning_hour,   :integer, null: false, default: 6
    add_column :tenants, :tod_afternoon_hour, :integer, null: false, default: 12
    add_column :tenants, :tod_evening_hour,   :integer, null: false, default: 18
    add_column :tenants, :tod_night_hour,     :integer, null: false, default: 22
    add_column :tenants, :time_zone,          :string,  null: false, default: "Europe/Rome"
  end
end
