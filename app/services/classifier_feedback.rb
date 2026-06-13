# Turns operator corrections into classifier inputs (P2-2 learning loop), so the
# system stops re-classifying the same caller from scratch every time.
#
#   examples:     up to MAX_EXAMPLES recent calls this tenant's operator manually
#                 labeled (mark_spam / mark_legit), as few-shot exemplars.
#   contact_hint: a one-line summary of how this caller has been classified
#                 before, appended to the system prompt.
#
# Read-only and bounded; safe to call on the screening hot-ish path (it runs in
# the async ScreeningJob, not the webhook).
class ClassifierFeedback
  MAX_EXAMPLES = 5
  SCAN_LIMIT   = 60

  Result = Struct.new(:examples, :contact_hint, keyword_init: true)

  def self.for(tenant:, contact:)
    new(tenant: tenant, contact: contact).build
  end

  def initialize(tenant:, contact:)
    @tenant  = tenant
    @contact = contact
  end

  def build
    Result.new(examples: examples, contact_hint: contact_hint)
  end

  private

  def contact_hint
    return nil unless @contact
    spam  = @contact.calls.where(status: :spam).count
    legit = @contact.calls.where(status: :legit).count
    return nil if spam.zero? && legit.zero?
    "Operator history for this caller (#{@contact.phone}): previously resolved spam #{spam}×, legit #{legit}×."
  end

  # Recent operator-corrected calls with a usable transcript, de-duplicated by
  # call. Bounded scan; capped at MAX_EXAMPLES.
  def examples
    logs = AuditLog.where(tenant_id: @tenant.id, subject_type: "Call",
                          action: %w[mark_spam mark_legit])
                   .recent.limit(SCAN_LIMIT)

    seen = {}
    out  = []
    logs.each do |log|
      break if out.size >= MAX_EXAMPLES
      next if seen[log.subject_id]
      seen[log.subject_id] = true
      call = Call.find_by(id: log.subject_id)
      next unless call && call.screening_transcript.present?
      out << { transcript: call.screening_transcript,
               label: log.action == "mark_spam" ? "spam" : "legit" }
    end
    out
  end
end
