# Maps a Date / Time / DateTime to the set of `Phrase#day_of_week` enum
# values it should match. A Tuesday call matches phrases with
# day_of_week ∈ {tuesday, weekday, any}; a Saturday call matches
# {saturday, weekend, any}.
#
# Used by PhrasePoolResolver via `Phrase.matching_day(...)` to filter
# the candidate pool. Single eligibility check per call — no per-tier
# explosion of the 7-tier resolver chain.
class DayOfWeekSlot
  WEEKDAY_SET = %i[monday tuesday wednesday thursday friday].freeze
  WEEKEND_SET = %i[saturday sunday].freeze
  WDAY_SYMS   = %i[sunday monday tuesday wednesday thursday friday saturday].freeze

  def self.current(now = Time.current)
    WDAY_SYMS[now.wday]
  end

  # Returns the array of strings that a phrase's day_of_week may equal
  # to be eligible for `day_or_date`.
  def self.eligible_values(day_or_date)
    sym = case day_or_date
    when Symbol then day_or_date
    when String then day_or_date.downcase.to_sym
    when Date, Time, DateTime, ActiveSupport::TimeWithZone
            current(day_or_date)
    else
            current
    end
    base = [ "any", sym.to_s ]
    base << "weekday" if WEEKDAY_SET.include?(sym)
    base << "weekend" if WEEKEND_SET.include?(sym)
    base
  end
end
