module Admin
  class DashboardController < BaseController
    def index
      @stats = {
        total_today: Call.today.count,
        spam_today: Call.today.spam.count,
        legit_today: Call.today.legit.count,
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
    end
  end
end
