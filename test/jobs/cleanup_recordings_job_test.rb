require "test_helper"

class CleanupRecordingsJobTest < ActiveJob::TestCase
  setup { @tenant = tenants(:default) }

  test "removes recordings older than auto_delete_days and nullifies path" do
    Setting.set("auto_delete_days", "30")

    old_path = Rails.root.join("storage/recordings/old-cleanup-test.wav")
    FileUtils.mkdir_p(old_path.dirname)
    File.binwrite(old_path, "old wav")

    old_call = @tenant.calls.create!(
      call_sid: "old-cleanup-test",
      from_number: "+390000000000",
      status: :completed,
      recording_local_path: old_path.to_s,
      created_at: 60.days.ago
    )

    new_path = Rails.root.join("storage/recordings/recent-cleanup-test.wav")
    File.binwrite(new_path, "recent wav")
    new_call = @tenant.calls.create!(
      call_sid: "recent-cleanup-test",
      from_number: "+390000000001",
      status: :completed,
      recording_local_path: new_path.to_s,
      created_at: 5.days.ago
    )

    CleanupRecordingsJob.new.perform

    assert_not File.exist?(old_path), "old recording should have been deleted"
    assert_nil old_call.reload.recording_local_path

    assert File.exist?(new_path), "recent recording should still exist"
    assert_equal new_path.to_s, new_call.reload.recording_local_path
  ensure
    FileUtils.rm_f(old_path) if defined?(old_path)
    FileUtils.rm_f(new_path) if defined?(new_path)
  end

  test "nullifies transcripts and ai_classification past retention (NEW H11 GDPR)" do
    Setting.set("auto_delete_transcripts_days", "30")

    old_call = @tenant.calls.create!(
      call_sid: "old-transcripts-test",
      from_number: "+393339999999",
      status: :completed,
      voicemail_transcript: "old voicemail content",
      screening_transcript: "old screening content",
      ai_classification: { "classification" => "spam", "confidence" => 0.9 },
      created_at: 60.days.ago
    )

    fresh_call = @tenant.calls.create!(
      call_sid: "fresh-transcripts-test",
      from_number: "+393338888888",
      status: :completed,
      voicemail_transcript: "recent voicemail",
      ai_classification: { "classification" => "legit", "confidence" => 0.8 },
      created_at: 5.days.ago
    )

    CleanupRecordingsJob.new.perform

    old_call.reload
    assert_nil old_call.voicemail_transcript
    assert_nil old_call.screening_transcript
    assert_nil old_call.ai_classification

    fresh_call.reload
    assert_equal "recent voicemail", fresh_call.voicemail_transcript
    assert_equal "legit", fresh_call.ai_classification["classification"]
  end

  test "cost columns survive transcript nullification" do
    Setting.set("auto_delete_transcripts_days", "30")

    old_call = @tenant.calls.create!(
      call_sid: "old-cost-survives",
      from_number: "+393337777777",
      status: :completed,
      voicemail_transcript: "old",
      screening_transcript: "old",
      ai_classification: { "classification" => "spam", "confidence" => 0.9 },
      ai_classification_source: "llm",
      moonshot_tokens_in: 412, moonshot_tokens_out: 64,
      moonshot_cost_usd: 0.000208,
      telnyx_cost_usd: 0.0014,
      billable_seconds: 12,
      created_at: 60.days.ago
    )

    CleanupRecordingsJob.new.perform

    old_call.reload
    assert_nil old_call.ai_classification
    # Persisted cost numbers must not be touched — that's the whole point.
    assert_equal "llm", old_call.ai_classification_source
    assert_equal 412, old_call.moonshot_tokens_in
    assert_in_delta 0.000208, old_call.moonshot_cost_usd.to_f, 1e-9
    assert_in_delta 0.0014, old_call.telnyx_cost_usd.to_f, 1e-9
    assert_equal 12, old_call.billable_seconds
  end

  test "sweeps orphan recordings older than retention, keeps referenced + recent files" do
    Setting.set("auto_delete_days", "30")
    dir = Rails.root.join("storage/recordings")
    FileUtils.mkdir_p(dir)
    orphan_old    = dir.join("orphan-old-sweep.wav")
    orphan_recent = dir.join("orphan-recent-sweep.wav")
    referenced    = dir.join("referenced-sweep.wav")
    [ orphan_old, orphan_recent, referenced ].each { |f| File.binwrite(f, "wav") }
    File.utime(40.days.ago.to_time, 40.days.ago.to_time, orphan_old)
    @tenant.calls.create!(call_sid: "ref-sweep-1", from_number: "+390000000009",
                          status: :completed, recording_local_path: referenced.to_s,
                          created_at: 5.days.ago)

    CleanupRecordingsJob.new.perform

    assert_not File.exist?(orphan_old), "old orphan should be swept"
    assert File.exist?(orphan_recent), "recent orphan should be kept"
    assert File.exist?(referenced), "referenced recording should be kept"
  ensure
    [ orphan_old, orphan_recent, referenced ].each { |f| FileUtils.rm_f(f) if f }
  end

  test "scrubs caller phone numbers from audit-log metadata past retention" do
    Setting.set("auto_delete_transcripts_days", "30")
    old_log = AuditLog.create!(action: "mark_spam", tenant: @tenant,
                               subject_type: "Call", subject_id: 1,
                               metadata: { "source" => "ntfy", "from" => "+393331112222" },
                               created_at: 60.days.ago)
    fresh_log = AuditLog.create!(action: "mark_spam", tenant: @tenant,
                                 subject_type: "Call", subject_id: 2,
                                 metadata: { "from" => "+393334445555" },
                                 created_at: 2.days.ago)

    CleanupRecordingsJob.new.perform

    old_log.reload
    assert_nil old_log.metadata["from"], "stale caller number should be scrubbed"
    assert_equal "ntfy", old_log.metadata["source"], "non-PII metadata kept"
    assert_equal "+393334445555", fresh_log.reload.metadata["from"], "recent log untouched"
  end
end
