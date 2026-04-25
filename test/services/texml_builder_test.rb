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

  test "record_voicemail output is valid XML with Say + Record" do
    xml = TexmlBuilder.record_voicemail(action_url: "https://example.test/recording?token=abc")
    doc = REXML::Document.new(xml)
    assert_not_nil REXML::XPath.first(doc, "//Record")
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
end
