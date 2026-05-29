# Watchdog for phrases wedged in render_status "rendering". PhraseRenderJob
# flips a phrase to "rendering" before shelling out; if the worker is SIGKILLed
# mid-render (OOM during a ~1.5 GB Chatterbox load, container redeploy, host
# reboot) no Ruby rescue runs, so the row is stuck "rendering" forever and the
# resolver silently skips it (Phrase.rendered only matches "rendered"). This
# re-enqueues any phrase stuck "rendering" past the threshold.
class RequeueStuckRendersJob < ApplicationJob
  queue_as :rendering

  STUCK_AFTER = 15.minutes

  def perform(stuck_after: STUCK_AFTER)
    Phrase.where(render_status: "rendering")
          .where(updated_at: ..stuck_after.ago)
          .find_each do |phrase|
      Rails.logger.warn("RequeueStuckRendersJob: re-enqueuing phrase #{phrase.id} stuck in 'rendering'")
      phrase.update_columns(render_status: "pending")
      PhraseRenderJob.perform_later(phrase.id)
    end
  end
end
