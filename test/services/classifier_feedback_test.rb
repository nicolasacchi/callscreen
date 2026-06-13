require "test_helper"

class ClassifierFeedbackTest < ActiveSupport::TestCase
  setup do
    @tenant  = tenants(:default)
    @contact = @tenant.contacts.create!(phone: "+393331110000")
  end

  test "no hint and no examples for a fresh tenant/contact" do
    fb = ClassifierFeedback.for(tenant: @tenant, contact: @contact)
    assert_nil fb.contact_hint
    assert_empty fb.examples
  end

  test "contact_hint summarises prior spam/legit resolutions for the caller" do
    @contact.calls.create!(tenant: @tenant, call_sid: "cf-a", from_number: @contact.phone, status: :spam)
    @contact.calls.create!(tenant: @tenant, call_sid: "cf-b", from_number: @contact.phone, status: :spam)
    @contact.calls.create!(tenant: @tenant, call_sid: "cf-c", from_number: @contact.phone, status: :legit)

    hint = ClassifierFeedback.for(tenant: @tenant, contact: @contact).contact_hint
    assert_includes hint, "spam 2"
    assert_includes hint, "legit 1"
  end

  test "examples are built from operator-corrected calls with transcripts, capped at MAX_EXAMPLES" do
    (ClassifierFeedback::MAX_EXAMPLES + 2).times do |i|
      call = @tenant.calls.create!(call_sid: "cf-ex-#{i}", from_number: "+39300000#{i}",
                                   status: :spam, screening_transcript: "offerta numero #{i}")
      AuditLog.record(action: "mark_spam", subject: call, tenant: @tenant, actor: nil)
    end

    examples = ClassifierFeedback.for(tenant: @tenant, contact: @contact).examples
    assert_equal ClassifierFeedback::MAX_EXAMPLES, examples.size
    assert(examples.all? { |e| e[:label] == "spam" && e[:transcript].present? })
  end

  test "skips corrected calls that have no transcript" do
    call = @tenant.calls.create!(call_sid: "cf-empty", from_number: "+393334445555",
                                 status: :legit, screening_transcript: nil)
    AuditLog.record(action: "mark_legit", subject: call, tenant: @tenant, actor: nil)
    assert_empty ClassifierFeedback.for(tenant: @tenant, contact: @contact).examples
  end
end
