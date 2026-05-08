# Removes WAV files for a deleted Phrase, deferred 10 minutes to absorb
# in-flight call playbacks. Runs on the :rendering queue so it doesn't
# block call-handling jobs.
#
# Takes the slug captured at delete time (NOT looked up from a fresh
# Phrase row), so a recycled slug won't accidentally wipe new audio.
class PhraseCleanupJob < ApplicationJob
  queue_as :rendering

  def perform(slug)
    return unless slug.is_a?(String) && slug.match?(/\A[a-z0-9_]{1,40}\z/)
    dir = Rails.root.join("storage", "greetings", slug)
    return unless dir.exist?
    # Only delete if no Phrase still owns this slug (race-safety).
    return if Phrase.where(slug: slug).exists?
    FileUtils.rm_rf(dir.to_s)
    Rails.logger.info("PhraseCleanupJob: removed #{dir}")
  end
end
