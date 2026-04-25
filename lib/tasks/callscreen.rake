namespace :callscreen do
  desc "Generate a new WEBHOOK_TOKEN; print it. Update env+Telnyx dashboard, then restart."
  task rotate_webhook_token: :environment do
    new_token = SecureRandom.alphanumeric(32)
    puts "New WEBHOOK_TOKEN: #{new_token}"
    puts "Set this in your env (e.g. compose-host/.env) and restart the container."
  end

  desc "Re-run SpamClassifier on a Call's stored screening transcript. Usage: rake callscreen:reclassify[CALL_ID]"
  task :reclassify, [ :call_id ] => :environment do |_t, args|
    call = Call.find(args[:call_id])
    abort "Call ##{call.id} has no screening_transcript" if call.screening_transcript.blank?

    result = SpamClassifier.new(call.screening_transcript, from_number: call.from_number).classify
    call.update!(ai_classification: result)
    puts "Reclassified Call ##{call.id}: #{result.inspect}"
  end

  desc "Purge failed Solid Queue jobs"
  task purge_failed_jobs: :environment do
    n = SolidQueue::FailedExecution.delete_all
    puts "Purged #{n} failed jobs"
  end
end
