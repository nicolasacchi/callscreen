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

  test "hangup with message includes Say + Hangup" do
    xml = TexmlBuilder.hangup(message: "Arrivederci")
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Say")
    assert_not_nil REXML::XPath.first(doc, "//Hangup")
  end

  test "reject contains a Reject element" do
    xml = TexmlBuilder.reject
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Reject")
  end

  test "escapes < > & in text content" do
    Setting.set("greeting_text", "Ciao <stranger> & friend")
    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)
    say_text = REXML::XPath.first(doc, "//Say").text
    assert_equal "Ciao <stranger> & friend", say_text
  end

  test "escapes double-quotes in attribute values (NEW H9 regression)" do
    # Bypass Setting.set validation to simulate a corrupted-DB scenario.
    # Even if the validator is bypassed, Nokogiri's attribute escaping must hold.
    Setting.where(key: "greeting_voice").destroy_all
    Setting.create!(key: "greeting_voice", value: 'alice"><Hangup/><Say voice="alice')

    xml = TexmlBuilder.greeting_and_gather(action_url: "https://example.test/screen")
    doc = REXML::Document.new(xml)

    say = REXML::XPath.first(doc, "//Say")
    assert_equal 'alice"><Hangup/><Say voice="alice', say.attribute("voice").value,
                 "voice attribute must round-trip the literal string without breaking XML"
    # The structural Hangup (after Gather) is intentional; assert exactly one.
    assert_equal 1, REXML::XPath.match(doc, "//Hangup").size
  end
end
