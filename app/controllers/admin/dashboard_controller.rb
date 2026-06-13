module Admin
  class DashboardController < BaseController
    def index
      tenant = viewing_tenant
      today_by_status = tenant.calls.today.group(:status).count
      @stats = {
        total_today:    today_by_status.values.sum,
        spam_today:     today_by_status["spam"]  || 0,
        legit_today:    today_by_status["legit"] || 0,
        recorded_today: tenant.calls.today.where.not(recording_url: nil).count,
        total_all:      tenant.calls.count,
        contacts:       tenant.contacts.count,
        whitelisted:    tenant.contacts.whitelisted.count,
        blacklisted:    tenant.contacts.blacklisted.count
      }

      @daily_calls = tenant.calls.where("created_at > ?", 30.days.ago)
                                 .group_by_day(:created_at)
                                 .count

      @daily_spam = tenant.calls.spam.where("created_at > ?", 30.days.ago)
                                .group_by_day(:created_at)
                                .count

      @recent_calls  = tenant.calls.recent.includes(:contact).limit(15)
      @recent_audits = AuditLog.where(tenant_id: tenant.id).recent.includes(:actor).limit(10)

      @insights = screening_insights(tenant)
    end

    private

    # Read-only screening-effectiveness rollup over the trailing 30 days (P2-6):
    # how much spam was caught, how much was blocked before ringing, the worst
    # repeat callers, and — on the subset the operator reviewed — how often the
    # LLM agreed with the operator's final call.
    INSIGHTS_WINDOW = 30.days

    def screening_insights(tenant)
      scope = tenant.calls.where(created_at: INSIGHTS_WINDOW.ago..)
      total = scope.count
      spam  = scope.spam.count
      {
        window_days:           (INSIGHTS_WINDOW / 1.day).to_i,
        total:                 total,
        spam:                  spam,
        spam_rate:             total.positive? ? (spam.to_f / total * 100).round(1) : 0.0,
        blocked_before_answer: scope.spam.where(answered_at: nil).count,
        top_spam_callers:      scope.spam.group(:from_number)
                                    .order(Arel.sql("COUNT(*) DESC")).limit(5).count,
        llm_accuracy:          llm_accuracy(tenant)
      }
    end

    # Of calls that were BOTH LLM-classified and operator-reviewed in the window,
    # the fraction where the LLM's classification matched the operator's final
    # status — a real accuracy signal, not mere audit-row existence.
    def llm_accuracy(tenant)
      ids = AuditLog.where(tenant_id: tenant.id, subject_type: "Call",
                           action: %w[mark_spam mark_legit], created_at: INSIGHTS_WINDOW.ago..)
                    .distinct.pluck(:subject_id)
      return nil if ids.empty?

      total = 0
      correct = 0
      tenant.calls.where(id: ids, ai_classification_source: "llm").find_each do |c|
        llm = c.ai_classification.is_a?(Hash) ? c.ai_classification["classification"] : nil
        next if llm.blank?
        total += 1
        correct += 1 if llm == c.status
      end
      total.positive? ? (correct.to_f / total * 100).round(1) : nil
    end
  end
end
