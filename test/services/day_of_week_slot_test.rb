require "test_helper"

class DayOfWeekSlotTest < ActiveSupport::TestCase
  test "Date input maps to specific day symbol" do
    monday = Date.new(2026, 5, 4)        # 2026-05-04 is a Monday
    saturday = Date.new(2026, 5, 9)
    assert_equal :monday,   DayOfWeekSlot.current(monday)
    assert_equal :saturday, DayOfWeekSlot.current(saturday)
  end

  test "Time input respects wday" do
    sunday = Time.zone.parse("2026-05-10 14:00")  # Sunday
    assert_equal :sunday, DayOfWeekSlot.current(sunday)
  end

  test "eligible_values for a weekday includes [day, weekday, any]" do
    eligible = DayOfWeekSlot.eligible_values(:tuesday)
    assert_includes eligible, "tuesday"
    assert_includes eligible, "weekday"
    assert_includes eligible, "any"
    refute_includes eligible, "weekend"
  end

  test "eligible_values for a weekend day includes [day, weekend, any]" do
    eligible = DayOfWeekSlot.eligible_values(:saturday)
    assert_includes eligible, "saturday"
    assert_includes eligible, "weekend"
    assert_includes eligible, "any"
    refute_includes eligible, "weekday"
  end

  test "eligible_values accepts a Date directly" do
    monday = Date.new(2026, 5, 4)
    eligible = DayOfWeekSlot.eligible_values(monday)
    assert_includes eligible, "monday"
    assert_includes eligible, "weekday"
  end

  test "eligible_values accepts a string" do
    eligible = DayOfWeekSlot.eligible_values("Friday")
    assert_includes eligible, "friday"
    assert_includes eligible, "weekday"
  end

  test "Phrase.matching_day filters correctly" do
    tenant = tenants(:default)
    p_any = Phrase.create!(tenant: tenant, slug: "p_any", label: "X",
                           kind: "user", text_it: "x", day_of_week: "any",
                           render_status: "rendered")
    p_weekday = Phrase.create!(tenant: tenant, slug: "p_weekday", label: "X",
                               kind: "user", text_it: "x", day_of_week: "weekday",
                               render_status: "rendered")
    p_tuesday = Phrase.create!(tenant: tenant, slug: "p_tuesday", label: "X",
                               kind: "user", text_it: "x", day_of_week: "tuesday",
                               render_status: "rendered")
    p_saturday = Phrase.create!(tenant: tenant, slug: "p_saturday", label: "X",
                                kind: "user", text_it: "x", day_of_week: "saturday",
                                render_status: "rendered")

    tuesday = Date.new(2026, 5, 5)
    saturday = Date.new(2026, 5, 9)

    tuesday_pool = Phrase.matching_day(tuesday).where(slug: %w[p_any p_weekday p_tuesday p_saturday]).pluck(:slug)
    assert_equal %w[p_any p_weekday p_tuesday].sort, tuesday_pool.sort

    saturday_pool = Phrase.matching_day(saturday).where(slug: %w[p_any p_weekday p_tuesday p_saturday]).pluck(:slug)
    assert_equal %w[p_any p_saturday].sort, saturday_pool.sort
  end
end
