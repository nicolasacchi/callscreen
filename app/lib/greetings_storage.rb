module GreetingsStorage
  # Test env writes to tmp/test_greetings so it can never destroy real audio
  # files in storage/greetings. Production uses the volume-mounted dir.
  ROOT = if Rails.env.test?
    Rails.root.join("tmp/test_greetings")
  else
    Rails.root.join("storage/greetings")
  end

  # Every path component must be a single safe token (lowercase letters,
  # digits, underscore). This confines writes/reads to ROOT and blocks path
  # traversal via an attacker-influenced `voice` (e.g. a tenant putting
  # "../../etc" into voice_rotation_voices). Kokoro voices (im_nicola),
  # cloned-voice dirs (_t12), tones (natural / natural_en) and phrase slugs
  # all match this; ".." and "/" do not.
  COMPONENT_FORMAT = /\A[a-z0-9_]+\z/

  def self.safe_component?(component)
    component.to_s.match?(COMPONENT_FORMAT)
  end

  def self.path_for(slug, voice, tone)
    [ slug, voice, tone ].each do |component|
      unless safe_component?(component)
        raise ArgumentError, "unsafe greeting path component: #{component.inspect}"
      end
    end
    ROOT.join(slug.to_s, voice.to_s, "#{tone}.wav")
  end
end
