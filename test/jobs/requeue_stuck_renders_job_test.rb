require "test_helper"

class RequeueStuckRendersJobTest < ActiveJob::TestCase
  setup { @tenant = tenants(:default) }

  test "re-enqueues a phrase wedged in 'rendering' and resets it to pending" do
    phrase = Phrase.create!(tenant: @tenant, slug: "stuck_render", label: "X", kind: "user", text_it: "x")
    phrase.update_columns(render_status: "rendering", updated_at: 30.minutes.ago)

    # The create-time render enqueue happens before this block, so it isn't counted.
    assert_enqueued_with(job: PhraseRenderJob, args: [ phrase.id ]) do
      RequeueStuckRendersJob.new.perform
    end
    assert_equal "pending", phrase.reload.render_status
  end

  test "leaves a recently-rendering phrase alone" do
    phrase = Phrase.create!(tenant: @tenant, slug: "fresh_render", label: "X", kind: "user", text_it: "x")
    phrase.update_columns(render_status: "rendering") # updated_at = now

    assert_no_enqueued_jobs only: PhraseRenderJob do
      RequeueStuckRendersJob.new.perform
    end
    assert_equal "rendering", phrase.reload.render_status
  end
end
