operator_email = ENV.fetch("ADMIN_EMAIL", "admin@callscreen.local")
operator_password = ENV.fetch("ADMIN_PASSWORD") do
  if Rails.env.production?
    raise "ADMIN_PASSWORD environment variable is required in production"
  end
  "changeme123!"
end

# The single bootstrap tenant is the operator: super-admin + default tenant
# (used for fallback when an inbound call cannot be attributed to any other
# row via dedicated_number or History-Info).
operator_slug = operator_email.split("@").first.downcase.gsub(/[^a-z0-9._-]/, "-")

operator = Tenant.find_or_initialize_by(email: operator_email)
operator.password              ||= operator_password
operator.password_confirmation ||= operator_password
operator.slug                  ||= operator_slug
operator.name                  ||= operator_slug
operator.default_tenant          = true
operator.admin                   = true
operator.active                  = true
operator.save!

Setting::DEFAULTS.each do |key, value|
  Setting.find_or_create_by!(key: key) do |s|
    s.value = value
    s.description = key.humanize
  end
end

# --- Shared system + greeting phrases (tenant_id: nil) ---------------------
# Fresh databases are created via `db:schema:load`, which does NOT run the
# data migrations (populate_system_phrases / seed_spam_response_phrases). Without
# this block a from-scratch deploy ships with ZERO shared phrases, which breaks
# PhrasePoolResolver's tier-7 fallback (resolve! could return nil) and
# Tenant#greeting_variant validation. See the review finding DM-9.
#
# Idempotent: existing slugs are skipped, so this is a no-op on already-migrated
# databases and safe to run on every container boot. `insert_all` bypasses the
# Phrase after_commit render hook and validations (seed data is trusted); we
# enqueue renders explicitly afterwards so a fresh deploy builds its WAVs.
now = Time.current
phrase_rows = []

GreetingCatalog::VARIANTS.each do |variant|
  next if Phrase.exists?(tenant_id: nil, slug: variant.slug)
  phrase_rows << {
    tenant_id: nil, slug: variant.slug, label: variant.label, kind: "user",
    text_it: variant.text_by_language["it"], text_en: variant.text_by_language["en"],
    time_of_day: "any", day_of_week: "any",
    render_status: "rendered", last_rendered_at: now, created_at: now, updated_at: now
  }
end

GreetingCatalog::SYSTEM_PHRASES.each do |slug, texts|
  next if Phrase.exists?(tenant_id: nil, slug: slug)
  phrase_rows << {
    tenant_id: nil, slug: slug, label: slug.tr("_", " ").capitalize, kind: "system_#{slug}",
    text_it: texts["it"], text_en: texts["en"],
    time_of_day: "any", day_of_week: "any",
    render_status: "rendered", last_rendered_at: now, created_at: now, updated_at: now
  }
end

GreetingCatalog::SPAM_RESPONSE_PHRASES.each do |p|
  next if Phrase.exists?(tenant_id: nil, slug: p[:slug])
  phrase_rows << {
    tenant_id: nil, slug: p[:slug], label: p[:label], kind: "system_#{p[:slug]}",
    text_it: p[:text_it], text_en: p[:text_en],
    time_of_day: "any", day_of_week: "any",
    render_status: "pending", last_rendered_at: nil, created_at: now, updated_at: now
  }
end

if phrase_rows.any?
  Phrase.insert_all(phrase_rows)
  Phrase.where(tenant_id: nil, slug: phrase_rows.map { |r| r[:slug] }).find_each do |phrase|
    PhraseRenderJob.perform_later(phrase.id)
  rescue StandardError => e
    Rails.logger.warn("seeds: enqueue render for phrase #{phrase.slug} failed: #{e.class}: #{e.message}")
  end
  Rails.logger.info("seeds: created #{phrase_rows.size} shared phrases")
end
