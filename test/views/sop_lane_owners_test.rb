# frozen_string_literal: true

require "test_helper"

# [component] /stages/sop — the operator-facing accountability-swimlane
# infographic rendered from config/devops_vocabulary.yml.
#
# The unit test pins the parsed data; this pins what the OPERATOR actually reads.
# An owner is only right RELATIVE TO ITS LANE, so the assertion is scoped to each
# lane's own owner badge (`[data-test='sop-lane-owner'][data-lane=…]`) and reads
# the text inside it.
#
# It deliberately does NOT assert adjacency of sibling spans. That was the first
# attempt and it failed twice over: any benign sibling markup (a live dot, a
# status ring — `_release_owner_face.html.erb` already adds one to owner badges)
# breaks the pair, so the positive assertion is brittle; and once the pair can no
# longer form, a `refute_includes` on it passes vacuously, so the negative
# assertion protects nothing. Scoping to the container survives markup churn, and
# a wrong name inside a lane's own badge trips it however the surrounding HTML is
# rearranged.
#
# Scoping alone does NOT make the negative safe, though — a present-but-EMPTY
# badge would satisfy `assert_not_nil` and leave `refute_includes` asserting
# nothing. The non-empty check below closes that; without it this comment would be
# claiming a property the test does not hold, which is the same defect that sent
# this task back twice.
class SopLaneOwnersTest < ActionView::TestCase
  # The post-reslot truth, as the operator reads it off the page.
  LANE_OWNERS = { "Assemble" => "Avi", "Ship" => "Steffon" }.freeze

  def owner_badge(lane)
    css_select("[data-test='sop-lane-owner'][data-lane='#{lane}']").first
  end

  test "[component] each lane's owner badge names its post-reslot owner" do
    render template: "tasks/sop"

    LANE_OWNERS.each do |lane, owner|
      badge = owner_badge(lane)
      assert_not_nil badge, "expected a rendered owner badge for the #{lane} lane"
      assert_includes badge.text, owner, "the #{lane} lane must name #{owner} as its owner"
    end
  end

  test "[component] no lane's owner badge names the pre-reslot owner" do
    render template: "tasks/sop"

    # The inverse pairing, which is exactly what the page rendered for three weeks.
    LANE_OWNERS.each do |lane, correct_owner|
      wrong_owner = LANE_OWNERS.values.find { |o| o != correct_owner }
      badge = owner_badge(lane)

      assert_not_nil badge, "expected a rendered owner badge for the #{lane} lane"

      # assert_not_nil closes the MISSING case; it does not close the EMPTY one.
      # A present-but-textless badge would make the refute below pass while
      # asserting nothing — the same vacuity, one layer in. Anchor it first.
      refute_predicate badge.text.strip, :empty?,
        "the #{lane} lane's owner badge rendered no text, so the check below would pass vacuously"

      refute_includes badge.text, wrong_owner,
        "/stages/sop is teaching the operator that #{wrong_owner} owns #{lane} — that is the " \
        "pre-reslot inversion (Avi assembles at G3, Steffon ships at G4)"
    end
  end

  test "[component] every lane renders exactly one owner badge, keyed by its own lane" do
    render template: "tasks/sop"

    # Guards the scoping hook the two tests above depend on. Counting the TOTAL
    # alone does not do that: dropping data-lane leaves the total unchanged, and
    # two badges on Assemble with none on Ship also totals correctly. So assert
    # per-lane — one badge for each lane the vocabulary declares.
    Devops::Vocabulary.lanes.each do |lane|
      assert_equal 1, css_select("[data-test='sop-lane-owner'][data-lane='#{lane[:lane]}']").size,
        "expected exactly one owner badge keyed to the #{lane[:lane]} lane"
    end
  end
end
