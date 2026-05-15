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

ActiveRecord::Schema[8.1].define(version: 2026_05_09_120200) do
  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.integer "actor_id"
    t.datetime "created_at", null: false
    t.text "metadata"
    t.bigint "subject_id", null: false
    t.string "subject_type", null: false
    t.integer "tenant_id"
    t.index ["actor_id"], name: "index_audit_logs_on_actor_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_audit_logs_on_subject_type_and_subject_id"
    t.index ["tenant_id"], name: "index_audit_logs_on_tenant_id"
  end

  create_table "calls", force: :cascade do |t|
    t.text "ai_classification"
    t.string "ai_classification_source"
    t.datetime "answered_at"
    t.integer "billable_seconds"
    t.string "call_control_id"
    t.string "call_sid"
    t.integer "contact_id"
    t.datetime "created_at", null: false
    t.integer "duration_seconds"
    t.string "flow_state", default: "initiated", null: false
    t.string "from_number"
    t.datetime "hung_up_at"
    t.decimal "moonshot_cost_usd", precision: 12, scale: 8
    t.integer "moonshot_tokens_in"
    t.integer "moonshot_tokens_out"
    t.datetime "notified_at"
    t.string "recording_local_path"
    t.string "recording_url"
    t.text "screening_transcript"
    t.string "selected_phrase_slug"
    t.string "selected_voice"
    t.integer "status", default: 0, null: false
    t.decimal "telnyx_cost_usd", precision: 12, scale: 8
    t.integer "tenant_id", null: false
    t.string "to_number"
    t.integer "troll_segment_index", default: 0, null: false
    t.boolean "unattributed", default: false, null: false
    t.datetime "updated_at", null: false
    t.text "voicemail_transcript"
    t.index ["call_control_id"], name: "index_calls_on_call_control_id", unique: true
    t.index ["call_sid"], name: "index_calls_on_call_sid", unique: true
    t.index ["contact_id"], name: "index_calls_on_contact_id"
    t.index ["created_at"], name: "index_calls_on_created_at"
    t.index ["from_number"], name: "index_calls_on_from_number"
    t.index ["status"], name: "index_calls_on_status"
    t.index ["tenant_id", "flow_state"], name: "index_calls_on_tenant_id_and_flow_state"
    t.index ["tenant_id", "unattributed"], name: "index_calls_on_tenant_id_and_unattributed"
    t.index ["tenant_id"], name: "index_calls_on_tenant_id"
  end

  create_table "contact_phrases", force: :cascade do |t|
    t.integer "contact_id", null: false
    t.datetime "created_at", null: false
    t.integer "phrase_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id", "phrase_id"], name: "index_contact_phrases_on_contact_id_and_phrase_id", unique: true
    t.index ["contact_id"], name: "index_contact_phrases_on_contact_id"
    t.index ["phrase_id"], name: "index_contact_phrases_on_phrase_id"
  end

  create_table "contact_tags", force: :cascade do |t|
    t.integer "contact_id", null: false
    t.datetime "created_at", null: false
    t.integer "tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["contact_id", "tag_id"], name: "index_contact_tags_on_contact_id_and_tag_id", unique: true
    t.index ["contact_id"], name: "index_contact_tags_on_contact_id"
    t.index ["tag_id"], name: "index_contact_tags_on_tag_id"
  end

  create_table "contacts", force: :cascade do |t|
    t.boolean "blacklisted", default: false, null: false
    t.integer "calls_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "language"
    t.datetime "last_called_at"
    t.string "name"
    t.text "notes"
    t.string "phone", null: false
    t.integer "phrase_rotation_index", default: 0, null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.boolean "whitelisted", default: false, null: false
    t.index ["tenant_id", "phone"], name: "index_contacts_on_tenant_id_and_phone", unique: true
    t.index ["tenant_id"], name: "index_contacts_on_tenant_id"
  end

  create_table "phrase_tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "phrase_id", null: false
    t.integer "tag_id", null: false
    t.datetime "updated_at", null: false
    t.index ["phrase_id", "tag_id"], name: "index_phrase_tags_on_phrase_id_and_tag_id", unique: true
    t.index ["phrase_id"], name: "index_phrase_tags_on_phrase_id"
    t.index ["tag_id"], name: "index_phrase_tags_on_tag_id"
  end

  create_table "phrases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "day_of_week", default: "any", null: false
    t.string "kind", default: "user", null: false
    t.string "label", null: false
    t.string "last_render_error"
    t.datetime "last_rendered_at"
    t.string "render_status", default: "pending", null: false
    t.string "slug", limit: 40, null: false
    t.integer "tenant_id"
    t.text "text_en"
    t.text "text_it"
    t.string "time_of_day", default: "any", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "render_status", "time_of_day", "day_of_week"], name: "index_phrases_on_resolver_predicate"
    t.index ["tenant_id", "render_status", "time_of_day"], name: "index_phrases_on_tenant_id_and_render_status_and_time_of_day"
    t.index ["tenant_id", "slug"], name: "index_phrases_on_tenant_id_and_slug", unique: true
    t.index ["tenant_id"], name: "index_phrases_on_tenant_id"
  end

  create_table "rules", force: :cascade do |t|
    t.integer "action", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.integer "hit_count", default: 0, null: false
    t.integer "priority", default: 0, null: false
    t.integer "rule_type", null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.string "value", null: false
    t.index ["tenant_id"], name: "index_rules_on_tenant_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_tags_on_tenant_id_and_name", unique: true
    t.index ["tenant_id"], name: "index_tags_on_tenant_id"
  end

  create_table "tenant_phrases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "phrase_id", null: false
    t.integer "position", default: 0, null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["phrase_id"], name: "index_tenant_phrases_on_phrase_id"
    t.index ["tenant_id", "phrase_id"], name: "index_tenant_phrases_on_tenant_id_and_phrase_id", unique: true
    t.index ["tenant_id"], name: "index_tenant_phrases_on_tenant_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "admin", default: false, null: false
    t.integer "auto_blacklist_threshold", default: 3
    t.integer "auto_blacklist_window_days", default: 7
    t.boolean "auto_detect_language", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "dedicated_number"
    t.boolean "default_tenant", default: false, null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.string "forward_back_number"
    t.string "greeting_language", default: "it-IT"
    t.text "greeting_text"
    t.string "greeting_tone", default: "natural"
    t.string "greeting_variant", default: "informal_tu"
    t.string "greeting_voice", default: "im_nicola"
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.datetime "locked_at"
    t.integer "max_calls_per_caller_per_day", default: 10
    t.integer "max_recording_seconds", default: 120
    t.string "mobile_number"
    t.string "name"
    t.string "ntfy_priority", default: "default"
    t.string "ntfy_url"
    t.boolean "phrase_rotation_enabled", default: false, null: false
    t.integer "phrase_rotation_index", default: 0, null: false
    t.string "phrase_rotation_variants"
    t.string "railsdav_username"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "screening_speech_timeout", default: "3"
    t.integer "sign_in_count", default: 0, null: false
    t.string "slug"
    t.string "spam_response_mode", default: "silent", null: false
    t.float "spam_sensitivity", default: 0.5
    t.integer "spam_troll_max_seconds", default: 90, null: false
    t.string "time_zone", default: "Europe/Rome", null: false
    t.integer "tod_afternoon_hour", default: 12, null: false
    t.integer "tod_evening_hour", default: 18, null: false
    t.integer "tod_morning_hour", default: 6, null: false
    t.integer "tod_night_hour", default: 22, null: false
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.boolean "voice_clone_active", default: false, null: false
    t.datetime "voice_clone_consent_at"
    t.datetime "voice_clone_rendered_at"
    t.boolean "voice_rotation_enabled", default: false, null: false
    t.integer "voice_rotation_index", default: 0, null: false
    t.string "voice_rotation_voices"
    t.string "voice_sample_path"
    t.text "voicemail_prompt"
    t.index ["dedicated_number"], name: "index_tenants_on_dedicated_number", unique: true, where: "dedicated_number IS NOT NULL"
    t.index ["default_tenant"], name: "index_tenants_on_default_tenant", unique: true, where: "default_tenant = 1"
    t.index ["email"], name: "index_tenants_on_email", unique: true
    t.index ["mobile_number"], name: "index_tenants_on_mobile_number", unique: true
    t.index ["reset_password_token"], name: "index_tenants_on_reset_password_token", unique: true
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
    t.index ["unlock_token"], name: "index_tenants_on_unlock_token", unique: true
  end

  add_foreign_key "audit_logs", "tenants"
  add_foreign_key "audit_logs", "tenants", column: "actor_id"
  add_foreign_key "calls", "contacts"
  add_foreign_key "calls", "tenants"
  add_foreign_key "contact_phrases", "contacts"
  add_foreign_key "contact_phrases", "phrases"
  add_foreign_key "contact_tags", "contacts"
  add_foreign_key "contact_tags", "tags"
  add_foreign_key "contacts", "tenants"
  add_foreign_key "phrase_tags", "phrases"
  add_foreign_key "phrase_tags", "tags"
  add_foreign_key "phrases", "tenants"
  add_foreign_key "rules", "tenants"
  add_foreign_key "tags", "tenants"
  add_foreign_key "tenant_phrases", "phrases"
  add_foreign_key "tenant_phrases", "tenants"
end
