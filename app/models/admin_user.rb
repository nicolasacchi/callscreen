class AdminUser < ApplicationRecord
  self.table_name = "admins"

  devise :database_authenticatable, :rememberable, :validatable
end
