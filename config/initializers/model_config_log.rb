# Log the resolved LLM model + Whisper endpoint once at boot so config drift is
# observable (CFG-1 / P1-9). The screening hot path is latency-sensitive; if the
# compose default ever silently selects the slow reasoning model, this line in
# the boot log makes it visible instead of only showing up as mysterious
# per-call latency.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    Rails.logger.info(
      "config: MOONSHOT_MODEL=#{ENV.fetch('MOONSHOT_MODEL', 'moonshot-v1-8k')} " \
      "WHISPER_API_URL=#{ENV['WHISPER_API_URL'].presence || '(unset)'}"
    )
  end
end
