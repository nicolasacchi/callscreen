# Picks the voice used for every audio segment of a call's lifetime (greeting +
# goodbye + voicemail prompt) and caches it on Call#selected_voice, so the
# rotation cursor advances at most once per call no matter how many segments
# fire. Extracted from TelnyxController#pick_voice_for_call! (ARCH-2) to make
# the selection ladder independently testable.
#
# Order: voice rotation list → cloned voice (_t<id>) → tenant default voice.
class VoiceSelector
  def self.for_call!(call)
    new(call).pick!
  end

  def initialize(call)
    @call = call
  end

  def pick!
    return @call.selected_voice if @call.selected_voice.present?

    tenant = @call.tenant
    voice =
      if tenant.voice_rotation_ready?
        tenant.next_rotated_voice!
      elsif tenant.voice_clone_ready?
        tenant.cloned_voice_dir
      else
        tenant.greeting_voice
      end

    @call.update_columns(selected_voice: voice) if voice.present?
    voice
  end
end
