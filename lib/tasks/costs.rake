namespace :costs do
  desc "Backfill telnyx_cost_usd / moonshot_cost_usd for pre-migration calls"
  task backfill: :environment do
    scope = Call.where(telnyx_cost_usd: nil)
    total = scope.count
    puts "Backfilling #{total} call(s)…"

    n = 0
    scope.find_each do |call|
      # Pre-rollout calls have duration_seconds (recording length), not
      # the Telnyx-billed leg lifetime. Use it as a best-effort estimate;
      # new calls capture answered_at..hung_up_at properly.
      telnyx_secs = call.duration_seconds.to_i

      moonshot_cost = if call.ai_classification.present? &&
                         call.screening_transcript.present?
        Pricing.estimate_moonshot_from_chars(call.screening_transcript.length)
      else
        0.0
      end

      source = if call.ai_classification.present? &&
                  call.screening_transcript.present?
        "llm"
      end

      call.update_columns(
        telnyx_cost_usd:           Pricing.telnyx_voice_usd(telnyx_secs),
        moonshot_cost_usd:         moonshot_cost,
        ai_classification_source:  source
      )
      n += 1
    end
    puts "Backfilled #{n} call(s)."
  end
end
