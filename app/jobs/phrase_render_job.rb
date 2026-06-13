# Renders a single Phrase across the tenant's active voice set × tones.
# Runs on the dedicated `:rendering` queue so a bulk render storm doesn't
# block ScreeningJob / NotifyJob on the `:default` queue.
#
# Triggers:
#   - Phrase after_save when text_it/text_en changes
#   - Tenant adds a voice (rotation list / cloned voice activation)
#   - Admin "Render now" button
#
# When `voice:` is given, render only that voice; otherwise iterate the
# tenant's active voice set. For shared phrases (tenant_id: nil) the
# active voice set is the union across every tenant.
require "open3"

class PhraseRenderJob < ApplicationJob
  include TimedSubprocess

  queue_as :rendering
  discard_on ActiveRecord::RecordNotFound

  # On final exhaustion, surface the failure (Sentry) and pin the phrase to
  # render_status "failed" so a tenant's silently-broken greeting render leaves
  # an operator signal beyond the per-attempt log line. Mirrors the
  # VoiceCloneRenderJob exhaustion handler.
  retry_on StandardError, attempts: 3, wait: :polynomially_longer do |job, error|
    phrase_id = job.arguments.first
    Rails.logger.error("PhraseRenderJob giving up phrase #{phrase_id}: #{error.class}: #{error.message}")
    Sentry.capture_exception(error) if defined?(Sentry)
    Phrase.where(id: phrase_id).update_all(
      render_status: "failed",
      last_render_error: "#{error.class}: #{error.message.to_s.first(500)}"
    )
  end

  TONES = %w[natural slow].freeze
  RENDER_TIMEOUT_SECS = 180

  def perform(phrase_id, voice: nil)
    phrase = Phrase.find(phrase_id)
    voices = voice ? [ voice.to_s ] : voices_for(phrase)
    return mark_rendered_noop(phrase) if voices.empty?

    phrase.update!(render_status: "rendering", last_render_error: nil)

    voices.each do |v|
      TONES.each do |tone|
        render_one!(phrase, v, tone)
      end
    end

    phrase.update!(render_status: "rendered", last_rendered_at: Time.current,
                   last_render_error: nil)
  rescue StandardError => e
    Phrase.where(id: phrase_id).update_all(
      render_status: "failed",
      last_render_error: "#{e.class}: #{e.message.to_s.first(500)}"
    )
    raise
  end

  private

  def voices_for(phrase)
    tenants = phrase.tenant_id ? [ phrase.tenant ] : Tenant.all.to_a
    tenants.flat_map { |t| active_voices_for(t) }.uniq
  end

  def active_voices_for(tenant)
    set = []
    set << tenant.greeting_voice if tenant.greeting_voice.present?
    set.concat(tenant.voice_rotation_voice_list)
    # Cloned voices (prefix `_t<id>`) intentionally excluded: their
    # render path uses ChatterboxMultilingualTTS + audio_prompt + the
    # language-suffix tone scheme (`<tone>_en.wav`), which lives in
    # clone_render.py + VoiceCloneRenderJob. Cloned audio for a newly
    # authored phrase appears when the tenant re-runs voice clone.
    set.compact.uniq.reject { |v| v.blank? || v.to_s.start_with?("_t") }
  end

  def render_one!(phrase, voice, tone)
    out_path = GreetingsStorage.path_for(phrase.slug, voice, tone)
    FileUtils.mkdir_p(File.dirname(out_path))

    if Rails.env.test?
      # Tests don't actually render — they assert job behavior. The
      # script is exercised in script-level tests. Touch the path so
      # render_status: rendered isn't a lie.
      FileUtils.touch(out_path) unless File.exist?(out_path)
      return
    end

    cmd = [ tts_python, script_path,
            "--slug",    phrase.slug,
            "--text-it", phrase.text_it.to_s,
            "--text-en", phrase.text_en.to_s,
            "--voice",   voice,
            "--tone",    tone,
            "--out",     out_path.to_s ]

    Rails.logger.info("PhraseRenderJob: phrase=#{phrase.id} voice=#{voice} tone=#{tone}")
    run_timed(cmd, timeout: RENDER_TIMEOUT_SECS, label: "render_phrase")
  end

  def mark_rendered_noop(phrase)
    # No active voices = nothing to render right now. Leave status
    # `pending` so the trigger that adds a voice will re-enqueue.
    phrase.update_columns(render_status: "pending")
    Rails.logger.info("PhraseRenderJob: phrase=#{phrase.id} no active voices, deferred")
  end

  def script_path
    Rails.root.join("scripts", "render_phrase.py").to_s
  end

  def tts_python
    return ENV["TTS_VENV_PYTHON"] if ENV["TTS_VENV_PYTHON"].present?
    [ "/opt/tts_venv/bin/python", Rails.root.join(".venv", "bin", "python").to_s ]
      .find { |p| File.executable?(p) } || "python3"
  end
end
