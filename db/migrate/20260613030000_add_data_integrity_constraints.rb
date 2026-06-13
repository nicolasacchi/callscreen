class AddDataIntegrityConstraints < ActiveRecord::Migration[8.1]
  # P2-8: defense-in-depth DB constraints. Until now every enum/range invariant
  # was Ruby-only (bypassable by a `rails runner`, a seed, or raw SQL), and all
  # FKs were RESTRICT with cascade/nullify carried only in the Ruby `dependent:`
  # options. This adds CHECK constraints matching the model validations and
  # aligns ON DELETE with the existing `dependent:` semantics.
  #
  # Value sets are inlined as a FROZEN SNAPSHOT (not model constants) so this
  # migration keeps reproducing the same schema even as the models evolve; a
  # future allowed value gets its own migration. Back up before running
  # (docker-entrypoint now does); SQLite rebuilds each table and the migration
  # fails loudly if any existing row violates a new constraint.

  FLOW_STATES = %w[
    initiated answered screening_prompt_playing screening_recording recording
    transfer_dialing bridged hanging_up_after_speak spam_disclose_playing
    troll_playing done
  ].freeze
  RENDER_STATUSES = %w[pending rendering rendered failed].freeze
  PHRASE_KINDS = %w[
    user system_clarify system_voicemail_prompt system_goodbye_spam
    system_goodbye_short system_no_answer system_spam_disclose
    system_troll_intro system_troll_hold_loop system_troll_voice_menu
    system_troll_apology system_troll_disclose
  ].freeze
  TIMES_OF_DAY = %w[any morning afternoon evening night].freeze
  DAYS_OF_WEEK = %w[any weekday weekend monday tuesday wednesday thursday friday saturday sunday].freeze

  def up
    add_check_constraint :calls, "status >= 0 AND status <= 9", name: "calls_status_range"
    add_check_constraint :calls, in_list("flow_state", FLOW_STATES), name: "calls_flow_state_valid"

    add_check_constraint :tenants,
      "spam_sensitivity IS NULL OR (spam_sensitivity >= 0.0 AND spam_sensitivity <= 1.0)",
      name: "tenants_spam_sensitivity_range"
    add_check_constraint :tenants,
      "auto_blacklist_threshold IS NULL OR auto_blacklist_threshold >= 1",
      name: "tenants_auto_blacklist_threshold_positive"
    add_check_constraint :tenants, tod_hours_check, name: "tenants_tod_hours_range"

    add_check_constraint :phrases, in_list("render_status", RENDER_STATUSES), name: "phrases_render_status_valid"
    add_check_constraint :phrases, in_list("kind", PHRASE_KINDS), name: "phrases_kind_valid"
    add_check_constraint :phrases, in_list("time_of_day", TIMES_OF_DAY), name: "phrases_time_of_day_valid"
    add_check_constraint :phrases, in_list("day_of_week", DAYS_OF_WEEK), name: "phrases_day_of_week_valid"

    # Align ON DELETE with the Ruby `dependent:` options.
    replace_fk :calls, :contacts, on_delete: :nullify          # Contact has_many :calls, dependent: :nullify
    replace_fk :contact_phrases, :contacts, on_delete: :cascade
    replace_fk :contact_phrases, :phrases,  on_delete: :cascade
    replace_fk :contact_tags,    :contacts, on_delete: :cascade
    replace_fk :contact_tags,    :tags,     on_delete: :cascade
    replace_fk :phrase_tags,     :phrases,  on_delete: :cascade
    replace_fk :phrase_tags,     :tags,     on_delete: :cascade
    replace_fk :tenant_phrases,  :phrases,  on_delete: :cascade
    replace_fk :tenant_phrases,  :tenants,  on_delete: :cascade
  end

  def down
    remove_check_constraint :calls,   name: "calls_status_range"
    remove_check_constraint :calls,   name: "calls_flow_state_valid"
    remove_check_constraint :tenants, name: "tenants_spam_sensitivity_range"
    remove_check_constraint :tenants, name: "tenants_auto_blacklist_threshold_positive"
    remove_check_constraint :tenants, name: "tenants_tod_hours_range"
    remove_check_constraint :phrases, name: "phrases_render_status_valid"
    remove_check_constraint :phrases, name: "phrases_kind_valid"
    remove_check_constraint :phrases, name: "phrases_time_of_day_valid"
    remove_check_constraint :phrases, name: "phrases_day_of_week_valid"

    replace_fk :calls, :contacts, on_delete: nil
    %i[contact_phrases contact_tags phrase_tags tenant_phrases].each do |t|
      to_tables(t).each { |to| replace_fk t, to, on_delete: nil }
    end
  end

  private

  def in_list(column, values)
    quoted = values.map { |v| "'#{v}'" }.join(", ")
    "#{column} IN (#{quoted})"
  end

  def tod_hours_check
    %w[tod_morning_hour tod_afternoon_hour tod_evening_hour tod_night_hour]
      .map { |c| "(#{c} IS NULL OR (#{c} >= 0 AND #{c} <= 23))" }
      .join(" AND ")
  end

  def to_tables(join_table)
    {
      contact_phrases: %i[contacts phrases],
      contact_tags:    %i[contacts tags],
      phrase_tags:     %i[phrases tags],
      tenant_phrases:  %i[phrases tenants]
    }.fetch(join_table)
  end

  def replace_fk(from, to, on_delete:)
    remove_foreign_key from, to if foreign_key_exists?(from, to)
    add_foreign_key from, to, on_delete: on_delete
  end
end
