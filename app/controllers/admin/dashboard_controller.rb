module Admin
  class DashboardController < BaseController
    def index
      today_by_status = Call.today.group(:status).count
      @stats = {
        total_today: today_by_status.values.sum,
        spam_today: today_by_status["spam"] || 0,
        legit_today: today_by_status["legit"] || 0,
        recorded_today: Call.today.where.not(recording_url: nil).count,
        total_all: Call.count,
        contacts: Contact.count,
        whitelisted: Contact.whitelisted.count,
        blacklisted: Contact.blacklisted.count
      }

      @daily_calls = Call.where("created_at > ?", 30.days.ago)
                         .group_by_day(:created_at)
                         .count

      @daily_spam = Call.spam.where("created_at > ?", 30.days.ago)
                        .group_by_day(:created_at)
                        .count

      @recent_calls = Call.recent.includes(:contact).limit(15)
      @recent_audits = AuditLog.recent.includes(:admin_user).limit(10)
    end
  end
end
