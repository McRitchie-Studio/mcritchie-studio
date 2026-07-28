# frozen_string_literal: true

require "test_helper"

# [component] /stages/sop — the operator-facing accountability-swimlane
# infographic rendered from config/devops_vocabulary.yml.
#
# The unit test pins the parsed data; this pins what the OPERATOR actually reads.
# The swimlane header prints the owner and the lane name in adjacent spans, so an
# inverted owner is only visible as a PAIR — which is exactly how the 07-22 lane
# reslot went unnoticed here for three weeks. Asserting the rendered adjacency
# means the page cannot silently teach the wrong owner again.
class SopLaneOwnersTest < ActionView::TestCase
  # Every (span, next span) text pair in the rendered page. The owner/lane spans
  # are siblings, so a correct pairing appears here as one entry.
  def rendered_span_pairs
    Nokogiri::HTML::DocumentFragment.parse(rendered)
      .css("span")
      .each_cons(2)
      .map { |first, second| [first.text.strip, second.text.strip] }
  end

  test "[component] the swimlane pairs each lane with its post-reslot owner" do
    render template: "tasks/sop"

    pairs = rendered_span_pairs

    assert_includes pairs, ["Avi", "Assemble"], "the Assemble lane (G3) belongs to Avi"
    assert_includes pairs, ["Steffon", "Ship"], "the Ship lane (G4) belongs to Steffon"
  end

  test "[component] the swimlane never renders the pre-reslot owners" do
    render template: "tasks/sop"

    pairs = rendered_span_pairs

    refute_includes pairs, ["Steffon", "Assemble"],
      "pre-reslot inversion is back: /stages/sop is teaching the operator that Steffon assembles"
    refute_includes pairs, ["Avi", "Ship"],
      "pre-reslot inversion is back: /stages/sop is teaching the operator that Avi ships"
  end
end
