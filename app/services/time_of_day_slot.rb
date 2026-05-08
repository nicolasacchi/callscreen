# Resolves the TOD slot (:morning / :afternoon / :evening / :night) for a
# given tenant + moment in time. Wraparound semantics: the night slot
# covers the small hours of the morning (e.g. 02:00 → :night when
# tod_night_hour=22 and tod_morning_hour=6), because none of the four
# explicit boundaries match a 02:00 call.
class TimeOfDaySlot
  def self.current(tenant, now = Time.current)
    zone = tenant&.time_zone.presence || "Europe/Rome"
    hour = now.in_time_zone(zone).hour

    boundaries = [
      [ tenant&.tod_morning_hour   || 6,  :morning ],
      [ tenant&.tod_afternoon_hour || 12, :afternoon ],
      [ tenant&.tod_evening_hour   || 18, :evening ],
      [ tenant&.tod_night_hour     || 22, :night ]
    ].sort_by(&:first)

    chosen = boundaries.reverse.find { |h, _| hour >= h }
    (chosen || boundaries.last).last
  end
end
