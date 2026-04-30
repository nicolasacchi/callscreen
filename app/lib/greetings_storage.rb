module GreetingsStorage
  # Test env writes to tmp/test_greetings so it can never destroy real audio
  # files in storage/greetings. Production uses the volume-mounted dir.
  ROOT = if Rails.env.test?
    Rails.root.join("tmp/test_greetings")
  else
    Rails.root.join("storage/greetings")
  end

  def self.path_for(slug, voice, tone)
    ROOT.join(slug.to_s, voice.to_s, "#{tone}.wav")
  end
end
