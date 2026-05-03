require "test_helper"

class ScreeningJobTest < ActiveJob::TestCase
  CCID = "v3:screening-job-test-1"
  CALLER_FROM = "+393335554321"

  setup do
    @tenant = tenants(:default)
    @tenant.update!(spam_sensitivity: 0.5,
                    auto_blacklist_threshold: 3,
                    auto_blacklist_window_days: 7,
                    mobile_number: "+393990000001")
    @contact = @tenant.contacts.find_or_create_by!(phone: CALLER_FROM)
    @call = @tenant.calls.create!(
      call_sid: CCID, call_control_id: CCID,
      from_number: CALLER_FROM, to_number: "+390123456789",
      status: :screening, flow_state: "hanging_up_after_speak",
      contact: @contact,
      recording_url: "https://api.telnyx.com/v2/recordings/abc.wav"
    )
    # Stub the recording download — write a fake WAV.
    @download_path = Rails.root.join("storage", "recordings", "#{CCID}.wav")
    FileUtils.mkdir_p(@download_path.dirname)
    File.binwrite(@download_path, "RIFF dummy wav")
    stub_request(:get, "https://api.telnyx.com/v2/recordings/abc.wav")
      .to_return(status: 200, body: "RIFF dummy wav", headers: { "Content-Type" => "audio/wav" })
  end

  teardown { FileUtils.rm_f(@download_path) }

  # === Happy-path classification ===

  test "Italian caller (+39) → Whisper called with language=it" do
    captured = nil
    stub_request(:post, %r{faster-whisper.test:8000/v1/audio/transcriptions})
      .with { |req| captured = req.body.to_s; true }
      .to_return(status: 200, body: { text: "ciao" }.to_json)
    stub_moonshot("legit", 0.9, "ok")
    @call.update!(from_number: "+393339998888")

    ScreeningJob.new.perform(@call.id)

    assert_match(/name="language"\r?\n\r?\nit\b/m, captured)
  end

  test "Non-Italian caller → Whisper called with language=en" do
    captured = nil
    stub_request(:post, %r{faster-whisper.test:8000/v1/audio/transcriptions})
      .with { |req| captured = req.body.to_s; true }
      .to_return(status: 200, body: { text: "hello" }.to_json)
    stub_moonshot("legit", 0.9, "ok")
    @call.update!(from_number: "+14155551234")

    ScreeningJob.new.perform(@call.id)

    assert_match(/name="language"\r?\n\r?\nen\b/m, captured)
  end

  test "auto_detect_language=false pins Whisper to tenant.greeting_language" do
    @tenant.update!(auto_detect_language: false, greeting_language: "en-US")
    captured = nil
    stub_request(:post, %r{faster-whisper.test:8000/v1/audio/transcriptions})
      .with { |req| captured = req.body.to_s; true }
      .to_return(status: 200, body: { text: "x" }.to_json)
    stub_moonshot("legit", 0.9, "ok")
    @call.update!(from_number: "+393339998888")  # Italian caller, but tenant pinned EN

    ScreeningJob.new.perform(@call.id)

    assert_match(/name="language"\r?\n\r?\nen\b/m, captured)
  end

  test "high-confidence spam → status=spam, NotifyJob, leaves flow_state alone" do
    stub_whisper("Special offer for your phone bill!")
    stub_moonshot("spam", 0.95, "Robocall pattern")

    assert_enqueued_jobs 1, only: NotifyJob do
      ScreeningJob.new.perform(@call.id)
    end

    @call.reload
    assert_equal "spam", @call.status
    # flow_state is owned by the controller, not the job — the controller
    # already set hanging_up_after_speak before enqueueing this job.
    assert_equal "hanging_up_after_speak", @call.flow_state
    assert_equal "Special offer for your phone bill!", @call.screening_transcript
    assert_equal "Special offer for your phone bill!", @call.voicemail_transcript
    assert_equal "Robocall pattern", @call.ai_reason
    assert_in_delta 0.95, @call.ai_confidence, 0.001
    # Job no longer issues hangup — controller does that on call.speak.ended.
    assert_not_requested :post, "https://api.telnyx.com/v2/calls/#{CCID}/actions/hangup"
  end

  test "legit classification → status=legit + NotifyJob" do
    stub_whisper("Sono Mario, chiamo per il pranzo")
    stub_moonshot("legit", 0.9, "Personal call")

    assert_enqueued_jobs 1, only: NotifyJob do
      ScreeningJob.new.perform(@call.id)
    end
    assert_equal "legit", @call.reload.status
  end

  test "uncertain classification → status=uncertain + NotifyJob" do
    stub_whisper("ehm... ciao?")
    stub_moonshot("uncertain", 0.4, "Unclear")

    assert_enqueued_jobs 1, only: NotifyJob do
      ScreeningJob.new.perform(@call.id)
    end
    assert_equal "uncertain", @call.reload.status
  end

  test "low-confidence spam (below tenant.spam_sensitivity) is treated as uncertain" do
    @tenant.update!(spam_sensitivity: 0.9)
    stub_whisper("buongiorno")
    stub_moonshot("spam", 0.5, "Maybe spam")

    ScreeningJob.new.perform(@call.id)

    assert_equal "uncertain", @call.reload.status
  end

  test "low-confidence spam (above tenant.spam_sensitivity) is treated as spam" do
    @tenant.update!(spam_sensitivity: 0.3)
    stub_whisper("buongiorno")
    stub_moonshot("spam", 0.5, "Maybe spam")

    ScreeningJob.new.perform(@call.id)

    assert_equal "spam", @call.reload.status
  end

  # === Empty transcript ===

  test "empty Whisper transcript → status=unknown + NotifyJob, no LLM call" do
    stub_whisper("")
    moonshot_stub = stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")

    assert_enqueued_jobs 1, only: NotifyJob do
      ScreeningJob.new.perform(@call.id)
    end

    assert_not_requested moonshot_stub
    @call.reload
    assert_equal "unknown", @call.status
    assert_equal "", @call.screening_transcript
  end

  # === Keyword rule ===

  test "keyword-block rule short-circuits LLM" do
    @tenant.rules.create!(rule_type: :keyword, action: :block, value: "warranty", active: true)
    stub_whisper("Hi about your warranty plan")
    moonshot_stub = stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")

    ScreeningJob.new.perform(@call.id)

    assert_not_requested moonshot_stub
    @call.reload
    assert_equal "spam", @call.status
    assert_equal "Keyword rule: warranty", @call.ai_reason
    assert_in_delta 1.0, @call.ai_confidence, 0.001
  end

  # === Auto-blacklist ===

  test "auto-blacklist: 3rd spam in 7d flips contact.blacklisted + audit row" do
    # Two prior spam calls within window
    2.times do |i|
      @tenant.calls.create!(
        call_sid: "abl-prev-#{i}", call_control_id: "abl-prev-#{i}",
        from_number: CALLER_FROM, contact: @contact, status: :spam,
        created_at: (i + 1).days.ago
      )
    end
    stub_whisper("Special offer!")
    stub_moonshot("spam", 0.99, "Robocall")

    assert_difference -> { AuditLog.where(action: "auto_blacklist").count }, 1 do
      ScreeningJob.new.perform(@call.id)
    end

    @contact.reload
    assert @contact.blacklisted
    log = AuditLog.where(action: "auto_blacklist").last
    assert_nil log.actor_id, "system action — no human actor"
    assert_equal @tenant.id, log.tenant_id
    assert_equal @contact.id, log.subject_id
    assert_equal 3, log.metadata["spam_count"]
  end

  test "auto-blacklist: does not fire below threshold" do
    @tenant.calls.create!(
      call_sid: "abl-only-prev", call_control_id: "abl-only-prev",
      from_number: CALLER_FROM, contact: @contact, status: :spam,
      created_at: 1.day.ago
    )
    stub_whisper("warranty plan")
    stub_moonshot("spam", 0.99, "Robocall")

    assert_no_difference -> { AuditLog.where(action: "auto_blacklist").count } do
      ScreeningJob.new.perform(@call.id)
    end
    refute @contact.reload.blacklisted
  end

  test "auto-blacklist: ignores spam outside the window" do
    3.times do |i|
      @tenant.calls.create!(
        call_sid: "abl-old-#{i}", call_control_id: "abl-old-#{i}",
        from_number: CALLER_FROM, contact: @contact, status: :spam,
        created_at: 30.days.ago - i.hours
      )
    end
    stub_whisper("scam!")
    stub_moonshot("spam", 0.99, "Robocall")

    assert_no_difference -> { AuditLog.where(action: "auto_blacklist").count } do
      ScreeningJob.new.perform(@call.id)
    end
    refute @contact.reload.blacklisted
  end

  test "auto-blacklist: skips already-whitelisted contacts" do
    @contact.update!(whitelisted: true)
    3.times do |i|
      @tenant.calls.create!(
        call_sid: "abl-w-#{i}", call_control_id: "abl-w-#{i}",
        from_number: CALLER_FROM, contact: @contact, status: :spam,
        created_at: i.days.ago
      )
    end
    stub_whisper("warranty")
    stub_moonshot("spam", 0.99, "Robocall")

    assert_no_difference -> { AuditLog.where(action: "auto_blacklist").count } do
      ScreeningJob.new.perform(@call.id)
    end
    refute @contact.reload.blacklisted
    assert @contact.whitelisted
  end

  test "auto-blacklist: per-tenant threshold/window are honored" do
    @tenant.update!(auto_blacklist_threshold: 2, auto_blacklist_window_days: 1)
    @tenant.calls.create!(
      call_sid: "abl-tt-prev", call_control_id: "abl-tt-prev",
      from_number: CALLER_FROM, contact: @contact, status: :spam,
      created_at: 6.hours.ago
    )
    stub_whisper("scam")
    stub_moonshot("spam", 0.99, "Robocall")

    assert_difference -> { AuditLog.where(action: "auto_blacklist").count }, 1 do
      ScreeningJob.new.perform(@call.id)
    end
    assert @contact.reload.blacklisted
  end

  test "auto-blacklist: does NOT trigger on legit or uncertain classifications" do
    2.times do |i|
      @tenant.calls.create!(
        call_sid: "abl-le-#{i}", call_control_id: "abl-le-#{i}",
        from_number: CALLER_FROM, contact: @contact, status: :spam,
        created_at: i.days.ago
      )
    end
    stub_whisper("Sono Mario per il pranzo")
    stub_moonshot("legit", 0.9, "Real caller")

    assert_no_difference -> { AuditLog.where(action: "auto_blacklist").count } do
      ScreeningJob.new.perform(@call.id)
    end
    refute @contact.reload.blacklisted
  end

  # === Failure path ===

  test "Whisper non-2xx → empty transcript → status=unknown (Whisper swallows errors)" do
    stub_request(:post, %r{faster-whisper.test:8000/v1/audio/transcriptions})
      .to_return(status: 500, body: "{}")

    assert_enqueued_jobs 1, only: NotifyJob do
      ScreeningJob.new.perform(@call.id)
    end
    @call.reload
    # WhisperClient returns nil on failure → coerces to "" in the job → unknown.
    # Operator still gets a notification and can investigate the empty call.
    assert_equal "unknown", @call.status
  end

  test "RecordingDownloader failure → status=failed + raise (job retries)" do
    stub_request(:get, "https://api.telnyx.com/v2/recordings/abc.wav")
      .to_return(status: 500, body: "")
    assert_raises do
      ScreeningJob.new.perform(@call.id)
    end
    @call.reload
    assert_equal "failed", @call.status
    # flow_state is left untouched on failure — controller's call.hangup
    # handler will set it to "done" when Telnyx finalizes the leg.
    assert_equal "hanging_up_after_speak", @call.flow_state
  end

  private

  def stub_whisper(transcript)
    body = { text: transcript }.to_json
    stub_request(:post, %r{faster-whisper.test:8000/v1/audio/transcriptions})
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end

  def stub_moonshot(classification, confidence, reason)
    body = {
      choices: [ { message: { content: { classification:, confidence:, reason: }.to_json } } ]
    }.to_json
    stub_request(:post, "https://api.moonshot.ai/v1/chat/completions")
      .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
  end
end
