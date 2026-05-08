class PopulateSystemPhrases < ActiveRecord::Migration[8.1]
  # Seed the 10 catalog variants + 5 system phrases as shared rows
  # (`tenant_id: NULL`). All marked rendered since their WAVs already
  # exist on disk under storage/greetings/<slug>/<voice>/<tone>.wav.
  def up
    now = Time.current
    rows = []

    GreetingCatalog::VARIANTS.each do |variant|
      next if Phrase.where(tenant_id: nil, slug: variant.slug).exists?
      rows << {
        tenant_id:        nil,
        slug:             variant.slug,
        label:            variant.label,
        kind:             "user",
        text_it:          variant.text_by_language["it"],
        text_en:          variant.text_by_language["en"],
        time_of_day:      "any",
        render_status:    "rendered",
        last_rendered_at: now,
        created_at:       now,
        updated_at:       now
      }
    end

    GreetingCatalog::SYSTEM_PHRASES.each do |slug, texts|
      next if Phrase.where(tenant_id: nil, slug: slug).exists?
      rows << {
        tenant_id:        nil,
        slug:             slug,
        label:            slug.tr("_", " ").capitalize,
        kind:             "system_#{slug}",
        text_it:          texts["it"],
        text_en:          texts["en"],
        time_of_day:      "any",
        render_status:    "rendered",
        last_rendered_at: now,
        created_at:       now,
        updated_at:       now
      }
    end

    # `insert_all` skips validations + callbacks — we trust seed data and
    # don't want the after_commit hook to enqueue 15 render jobs for
    # already-rendered files.
    Phrase.insert_all(rows) if rows.any?
  end

  def down
    Phrase.where(tenant_id: nil).destroy_all
  end
end
