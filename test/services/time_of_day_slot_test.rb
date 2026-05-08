require "test_helper"

class TimeOfDaySlotTest < ActiveSupport::TestCase
  setup { @tenant = tenants(:default) }

  def at(hour, minute = 0)
    Time.zone.parse("2026-05-05 #{format('%02d:%02d', hour, minute)} +0200")
  end

  test "default boundaries: 06=morning, 12=afternoon, 18=evening, 22=night" do
    assert_equal :morning,   TimeOfDaySlot.current(@tenant, at(6))
    assert_equal :morning,   TimeOfDaySlot.current(@tenant, at(11))
    assert_equal :afternoon, TimeOfDaySlot.current(@tenant, at(12))
    assert_equal :afternoon, TimeOfDaySlot.current(@tenant, at(17))
    assert_equal :evening,   TimeOfDaySlot.current(@tenant, at(18))
    assert_equal :evening,   TimeOfDaySlot.current(@tenant, at(21))
    assert_equal :night,     TimeOfDaySlot.current(@tenant, at(22))
    assert_equal :night,     TimeOfDaySlot.current(@tenant, at(23))
  end

  test "early-morning hours wrap to night (small-hours fix)" do
    assert_equal :night, TimeOfDaySlot.current(@tenant, at(2))
    assert_equal :night, TimeOfDaySlot.current(@tenant, at(0))
    assert_equal :night, TimeOfDaySlot.current(@tenant, at(5, 59))
  end

  test "respects tenant time zone" do
    @tenant.update!(time_zone: "America/Los_Angeles")
    # 14:00 UTC = 06:00 in LA = morning
    assert_equal :morning, TimeOfDaySlot.current(@tenant, Time.utc(2026, 5, 5, 13, 0))
  end

  test "tolerates nil tenant (defaults applied)" do
    assert_equal :morning, TimeOfDaySlot.current(nil, at(6))
    assert_equal :night,   TimeOfDaySlot.current(nil, at(2))
  end

  test "respects custom boundaries" do
    @tenant.update!(tod_morning_hour: 7, tod_afternoon_hour: 13,
                    tod_evening_hour: 19, tod_night_hour: 23)
    assert_equal :night,     TimeOfDaySlot.current(@tenant, at(6))   # before morning
    assert_equal :morning,   TimeOfDaySlot.current(@tenant, at(7))
    assert_equal :afternoon, TimeOfDaySlot.current(@tenant, at(13))
    assert_equal :evening,   TimeOfDaySlot.current(@tenant, at(19))
    assert_equal :night,     TimeOfDaySlot.current(@tenant, at(23))
  end

  test "tenant validates monotonic ordering of TOD hours" do
    @tenant.tod_morning_hour = 12
    @tenant.tod_afternoon_hour = 6  # out of order
    refute @tenant.valid?
    assert_includes @tenant.errors.full_messages.to_s, "in order"
  end
end
