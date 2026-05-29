require "test_helper"

class PhraseRenderJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:default)
    @tenant.update!(greeting_voice: "im_nicola",
                    voice_rotation_voices: "if_sara,im_nicola",
                    voice_clone_active: false)
  end

  test "uses :rendering queue" do
    assert_equal "rendering", PhraseRenderJob.new.queue_name
  end

  test "happy path: status flips pending → rendered" do
    p = phrases(:informal_tu)
    p.update_columns(render_status: "pending")
    PhraseRenderJob.perform_now(p.id)
    assert_equal "rendered", p.reload.render_status
    assert p.last_rendered_at
  end

  test "voice argument restricts to one voice" do
    p = Phrase.create!(tenant: @tenant, slug: "render_voice_arg",
                       label: "X", kind: "user", text_it: "x")
    PhraseRenderJob.perform_now(p.id, voice: "im_nicola")
    assert_equal "rendered", p.reload.render_status
  end

  test "no active voices → defers (status remains pending)" do
    @tenant.update!(greeting_voice: "", voice_rotation_voices: "",
                    voice_clone_active: false)
    p = Phrase.create!(tenant: @tenant, slug: "no_voices_yet",
                       label: "X", kind: "user", text_it: "x")
    p.update_columns(render_status: "pending")  # bypass after_save enqueue
    PhraseRenderJob.perform_now(p.id)
    assert_equal "pending", p.reload.render_status
  end

  test "active voice set excludes cloned voice prefix" do
    # Defense-in-depth: even if a _t* clone dir slips into the list (the
    # Tenant validator now blocks non-owned ones, so bypass it here),
    # active_voices_for must still exclude every _t* entry — clones render
    # via a separate Chatterbox path, not this job.
    @tenant.update_columns(voice_rotation_voices: "im_nicola,_t99,af_heart")
    job = PhraseRenderJob.new
    voices = job.send(:active_voices_for, @tenant)
    refute_includes voices, "_t99"
    assert_includes voices, "im_nicola"
    assert_includes voices, "af_heart"
  end

  test "missing phrase is discarded, not retried" do
    # discard_on ActiveRecord::RecordNotFound swallows the error so the
    # job doesn't raise and doesn't retry. Calling perform_now should be
    # silent.
    assert_nothing_raised do
      PhraseRenderJob.perform_now(999_999_999)
    end
  end

  test "shared (tenant_id: nil) phrase unions all tenants' active voices" do
    other = tenants(:other)
    other.update!(greeting_voice: "am_michael", voice_rotation_voices: "")
    p = phrases(:informal_tu)
    job = PhraseRenderJob.new
    voices = job.send(:voices_for, p)
    assert_includes voices, "im_nicola"
    assert_includes voices, "am_michael"
  end
end
