# frozen_string_literal: true

require "test_helper"

# [unit] DreamLoopHelper: a dream's heat level and grade label, and an empty KPI.
class DreamLoopHelperTest < ActionView::TestCase
  test "[unit] heat is cold before a fire, warm from one, hot from five" do
    assert_equal %w[cold warm warm hot hot], [ 0, 1, 4, 5, 40 ].map { |fires| dream_heat_level(fires) }
    assert_includes dream_heat_classes(5), "text-danger-ink"
  end

  test "[unit] the grade label reads the mean to one place, and nothing before a grade" do
    assert_equal "graded 1.5 (2)", dream_grade_label(DreamGrade::Summary.new(mean: 1.5, count: 2))
    assert_nil dream_grade_label(nil)
    assert_nil dream_grade_label(DreamGrade::Summary.new(mean: 0.0, count: 0))
  end

  test "[unit] a KPI with no data reads as a dash" do
    assert_equal "—", dream_kpi(nil, " d")
    assert_equal "2.5 d", dream_kpi(2.5, " d")
  end
end
