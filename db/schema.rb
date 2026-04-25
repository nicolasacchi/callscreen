# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_25_150100) do
  create_table "admins", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.datetime "locked_at"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admins_on_email", unique: true
    t.index ["reset_password_token"], name: "index_admins_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_admins_on_unlock_token", unique: true
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.integer "admin_user_id", null: false
    t.datetime "created_at", null: false
    t.text "metadata"
    t.bigint "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["admin_user_id"], name: "index_audit_logs_on_admin_user_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_audit_logs_on_subject_type_and_subject_id"
  end

  create_table "calls", force: :cascade do |t|
    t.text "ai_classification"
    t.string "call_sid"
    t.integer "contact_id"
    t.datetime "created_at", null: false
    t.integer "duration_seconds"
    t.string "from_number"
    t.datetime "notified_at"
    t.string "recording_local_path"
    t.string "recording_url"
    t.text "screening_transcript"
    t.integer "status", default: 0, null: false
    t.string "to_number"
    t.datetime "updated_at", null: false
    t.text "voicemail_transcript"
    t.index ["call_sid"], name: "index_calls_on_call_sid", unique: true
    t.index ["contact_id"], name: "index_calls_on_contact_id"
    t.index ["created_at"], name: "index_calls_on_created_at"
    t.index ["from_number"], name: "index_calls_on_from_number"
    t.index ["status"], name: "index_calls_on_status"
  end

  create_table "contacts", force: :cascade do |t|
    t.boolean "blacklisted", default: false, null: false
    t.integer "calls_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "last_called_at"
    t.string "name"
    t.text "notes"
    t.string "phone", null: false
    t.datetime "updated_at", null: false
    t.boolean "whitelisted", default: false, null: false
    t.index ["phone"], name: "index_contacts_on_phone", unique: true
  end

  create_table "rules", force: :cascade do |t|
    t.integer "action", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.integer "hit_count", default: 0, null: false
    t.integer "priority", default: 0, null: false
    t.integer "rule_type", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  add_foreign_key "audit_logs", "admins", column: "admin_user_id"
  add_foreign_key "calls", "contacts"
end
