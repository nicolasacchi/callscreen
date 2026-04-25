require "test_helper"

class RuleTest < ActiveSupport::TestCase
  test "prefix rule matches phone numbers starting with value" do
    r = Rule.new(rule_type: :prefix, action: :block, value: "+39899")
    assert r.matches_number?("+393999999999".sub("+39", "+39899"))
    assert r.matches_number?("+39899123")
    assert_not r.matches_number?("+393331111111")
  end

  test "regex rule matches via Regexp.new with timeout" do
    r = Rule.new(rule_type: :regex, action: :block, value: '\A\+39800')
    assert r.matches_number?("+39800123456")
    assert_not r.matches_number?("+39333123456")
  end

  test "keyword rule matches case-insensitively against transcript" do
    r = Rule.new(rule_type: :keyword, action: :block, value: "Warranty")
    assert r.matches_transcript?("call about your warranty plan")
    assert_not r.matches_transcript?("ciao")
  end

  test "keyword rule does NOT match against phone numbers via matches_number?" do
    r = Rule.new(rule_type: :keyword, action: :block, value: "spam")
    assert_not r.matches_number?("+39899")
  end

  test "rejects malformed regex (unclosed group)" do
    r = Rule.new(rule_type: :regex, action: :block, value: "(unclosed[")
    assert_not r.valid?
    assert r.errors[:value].any? { |msg| msg.include?("not a valid regex") }
  end

  test "rejects malformed regex (bad quantifier)" do
    r = Rule.new(rule_type: :regex, action: :block, value: "*+?")
    assert_not r.valid?
    assert r.errors[:value].any? { |msg| msg.include?("not a valid regex") }
  end

  test "global Regexp.timeout is bounded at 1 second (defense in depth)" do
    assert_equal 1.0, Regexp.timeout
  end

  test "accepts safe regex" do
    r = Rule.new(rule_type: :regex, action: :block, value: '\A\+39\d{9,10}\z')
    assert r.valid?, r.errors.full_messages.inspect
  end

  test "active scope returns only active rules ordered by priority desc" do
    Rule.update_all(active: false)
    high = Rule.create!(rule_type: :prefix, action: :block, value: "+1", active: true, priority: 100)
    low  = Rule.create!(rule_type: :prefix, action: :block, value: "+2", active: true, priority: 1)
    inactive = Rule.create!(rule_type: :prefix, action: :block, value: "+3", active: false, priority: 999)

    result = Rule.active.to_a
    assert_equal [ high, low ], result.first(2)
    assert_not_includes result, inactive
  end
end
