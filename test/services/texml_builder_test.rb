require "test_helper"
require "rexml/document"

class TexmlBuilderTest < ActiveSupport::TestCase
  test "greeting_and_gather output is valid XML with Gather + Say" do
    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen?token=abc")
    doc = REXML::Document.new(xml)
    assert_not_nil doc.root
    assert_equal "Response", doc.root.name
    assert_not_nil REXML::XPath.first(doc, "//Gather")
    assert_not_nil REXML::XPath.first(doc, "//Say")
  end

  test "greeting_and_gather sets transcriptionEngine on Gather (Telnyx requires explicit engine)" do
    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)
    gather = REXML::XPath.first(doc, "//Gather")
    assert_equal "Google", gather.attribute("transcriptionEngine").value,
                 "Without transcriptionEngine, Telnyx returns empty SpeechResult"
    assert_equal "speech", gather.attribute("input").value
    assert_equal "10", gather.attribute("timeout").value,
                 "Default 5s pre-speech wait is too short after the Italian greeting"
  end

  test "greeting_and_gather reads transcription_engine from Setting" do
    Setting.set("transcription_engine", "Telnyx")
    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)
    gather = REXML::XPath.first(doc, "//Gather")
    assert_equal "Telnyx", gather.attribute("transcriptionEngine").value
  end

  test "record_voicemail output is valid XML with Say + Record" do
    xml = TexmlBuilder.record_voicemail(action_url: "https://example.test/recording?token=abc")
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Record")
  end

  test "record_voicemail Record sets recordingStatusCallback so hangups still deliver the recording" do
    xml = TexmlBuilder.record_voicemail(action_url: "https://example.test/recording")
    doc = REXML::Document.new(xml)
    record = REXML::XPath.first(doc, "//Record")
    assert_equal "https://example.test/recording", record.attribute("recordingStatusCallback").value,
                 "Without recordingStatusCallback, hangup-during-recording skips the action callback"
    assert_equal "5", record.attribute("timeout").value
  end

  test "forward_call wraps the number in Dial" do
    xml = TexmlBuilder.forward_call("+390123456789")
    doc = REXML::Document.new(xml)
    dial = REXML::XPath.first(doc, "//Dial")
    assert_equal "+390123456789", dial.text
  end

  test "hangup with no phrase emits just Hangup" do
    xml = TexmlBuilder.hangup
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Hangup")
    assert_nil REXML::XPath.first(doc, "//Say"), "no Say should be emitted when phrase is nil"
    assert_nil REXML::XPath.first(doc, "//Play")
  end

  test "hangup with phrase falls back to Say with safe alice voice when audio missing" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/goodbye_spam", voice, "#{tone}.wav")
    FileUtils.rm_f(audio)

    xml = TexmlBuilder.hangup(phrase: "goodbye_spam")
    doc = REXML::Document.new(xml)
    say = REXML::XPath.first(doc, "//Say")
    assert_not_nil say
    assert_equal GreetingCatalog::SYSTEM_PHRASES["goodbye_spam"], say.text
    assert_equal "alice", say.attribute("voice").value
    assert_not_nil REXML::XPath.first(doc, "//Hangup")
  end

  test "hangup with phrase emits Play when pre-rendered audio exists" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/goodbye_spam", voice, "#{tone}.wav")
    FileUtils.mkdir_p(audio.dirname)
    File.binwrite(audio, "RIFF dummy")

    xml = TexmlBuilder.hangup(phrase: "goodbye_spam")
    doc = REXML::Document.new(xml)
    play = REXML::XPath.first(doc, "//Play")
    assert_not_nil play
    assert_match %r{/greetings/goodbye_spam/#{voice}/#{tone}\.wav\z}, play.text
    assert_nil REXML::XPath.first(doc, "//Say")
    assert_not_nil REXML::XPath.first(doc, "//Hangup")
  ensure
    FileUtils.rm_f(audio) if audio
  end

  test "record_voicemail emits Play of voicemail_prompt when audio exists" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/voicemail_prompt", voice, "#{tone}.wav")
    FileUtils.mkdir_p(audio.dirname)
    File.binwrite(audio, "RIFF dummy")

    xml = TexmlBuilder.record_voicemail(action_url: "https://example.test/recording")
    doc = REXML::Document.new(xml)
    play = REXML::XPath.first(doc, "//Play")
    assert_not_nil play
    assert_match %r{/greetings/voicemail_prompt/#{voice}/#{tone}\.wav\z}, play.text
    assert_not_nil REXML::XPath.first(doc, "//Record")
  ensure
    FileUtils.rm_f(audio) if audio
  end

  test "record_voicemail falls back to Say with safe alice voice when audio missing" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/voicemail_prompt", voice, "#{tone}.wav")
    FileUtils.rm_f(audio)

    xml = TexmlBuilder.record_voicemail(action_url: "https://example.test/recording")
    doc = REXML::Document.new(xml)
    say = REXML::XPath.first(doc, "//Say")
    assert_not_nil say
    assert_equal GreetingCatalog::SYSTEM_PHRASES["voicemail_prompt"], say.text
    assert_equal "alice", say.attribute("voice").value, "fallback must use Telnyx-safe alice, not Kokoro voice id"
    assert_not_nil REXML::XPath.first(doc, "//Record")
  end

  test "reject contains a Reject element" do
    xml = TexmlBuilder.reject
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Reject")
  end

  test "greeting_and_gather emits Play when pre-rendered audio exists" do
    slug = Setting.get("greeting_variant")
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings", slug, voice, "#{tone}.wav")
    FileUtils.mkdir_p(audio.dirname)
    File.binwrite(audio, "RIFF dummy wav data")

    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)
    play = REXML::XPath.first(doc, "//Play")
    assert_not_nil play
    assert_match %r{/greetings/#{slug}/#{voice}/#{tone}\.wav\z}, play.text
    # No Say should be emitted inside the Gather when Play is used
    gather_say = REXML::XPath.first(doc, "//Gather/Say")
    assert_nil gather_say
  ensure
    FileUtils.rm_f(audio) if audio
  end

  test "clarify_and_gather emits Play when clarify audio exists" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/clarify", voice, "#{tone}.wav")
    FileUtils.mkdir_p(audio.dirname)
    File.binwrite(audio, "RIFF clarify dummy")

    xml = TexmlBuilder.clarify_and_gather(action_url: "https://example.test/clarify")
    doc = REXML::Document.new(xml)
    play = REXML::XPath.first(doc, "//Play")
    assert_not_nil play
    assert_match %r{/greetings/clarify/#{voice}/#{tone}\.wav\z}, play.text
    gather = REXML::XPath.first(doc, "//Gather")
    assert_equal "https://example.test/clarify", gather.attribute("action").value
  ensure
    FileUtils.rm_f(audio) if audio
  end

  test "clarify_and_gather falls back to Say with the system phrase when audio missing" do
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings/clarify", voice, "#{tone}.wav")
    FileUtils.rm_f(audio)

    xml = TexmlBuilder.clarify_and_gather(action_url: "https://example.test/clarify")
    doc = REXML::Document.new(xml)
    say = REXML::XPath.first(doc, "//Gather/Say")
    assert_not_nil say
    assert_equal GreetingCatalog::SYSTEM_PHRASES["clarify"], say.text
    assert_equal "alice", say.attribute("voice").value
  end

  test "greeting_and_gather falls back to Say when audio file is missing" do
    slug = Setting.get("greeting_variant")
    voice = Setting.get("greeting_voice")
    tone = Setting.get("greeting_tone")
    audio = Rails.root.join("storage/greetings", slug, voice, "#{tone}.wav")
    FileUtils.rm_f(audio)

    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)
    play = REXML::XPath.first(doc, "//Gather/Play")
    say = REXML::XPath.first(doc, "//Gather/Say")

    assert_nil play, "Should not emit Play when file is missing"
    assert_not_nil say, "Should fall back to Say"
    assert_equal GreetingCatalog.text_for(slug), say.text
    assert_equal "alice", say.attribute("voice").value, "Fallback Say must use safe Telnyx voice"
  end
end
