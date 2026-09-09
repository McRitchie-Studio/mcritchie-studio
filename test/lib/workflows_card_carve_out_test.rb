require "test_helper"

# [unit] AN ACT KEPT OFF THE WORKFLOWS CARD MUST SAY SO IN THE PLACE PEOPLE EDIT.
#
# Chip membership is decided in two files, and the reason for a MISSING chip lives in
# a comment. A comment cannot fail, so the reason drifts silently — which is exactly
# what happened: PR #1322 registered `sleeper-auction-watch` as deliberately off the
# card and corrected four sites, and the fifth — the comment sitting directly above
# `card_actions` in tasks/_heartbeats_card, the first thing a developer editing chip
# membership reads — kept telling the old two-act story. Silence is what let that
# drift happen, so the silence is what this file ends.
#
# The carve-out set is DERIVED from the helper docblock's "+act+ is deliberately
# ABSENT" convention rather than restated here, so a third carve-out is pinned the
# day it is written instead of the day someone remembers to add an assertion.
#
# It also closes a hole the existing pin cannot see. The helper test asserts
# `assert_not_includes heartbeat_launchers.flat_map { _1[:actions] }` — but the card
# does NOT render that list for three of the five souls. tasks/_heartbeats_card
# overrides Carl, Avi and Steffon with its own `card_actions` case literals, so a
# chip added THERE renders on the card while every helper assertion stays green.
# Both sources are checked below.
class WorkflowsCardCarveOutTest < ActiveSupport::TestCase
  HELPER = Rails.root.join("app/helpers/application_helper.rb")
  CARD   = Rails.root.join("app/views/tasks/_heartbeats_card.html.erb")

  # The acts the helper docblock declares deliberately off the card.
  def carve_outs
    HELPER.read.scan(/\+([a-z][a-z0-9-]+)\+ is deliberately ABSENT/).flatten.uniq
  end

  # The chip lists tasks/_heartbeats_card writes itself, overriding the helper for
  # Carl, Avi and Steffon. These are the acts that actually render for those souls.
  def card_action_literals
    region = CARD.read[/card_actions = case.*?\bend\b/m]
    region.to_s.scan(/when\s+"[a-z-]+"\s+then\s+\[([^\]]*)\]/).flatten
          .flat_map { |list| list.scan(/"([^"]+)"/).flatten }
  end

  # The comment block immediately above `card_actions` — the one a developer editing
  # chip membership reads before touching anything.
  def carve_out_comment
    before = CARD.read.split("card_actions = case").first.to_s
    before[before.rindex("<%#").to_i..].to_s
  end

  test "[unit] the helper's deliberately-ABSENT convention still parses" do
    # Control against a silent reword: if the docblock stops using this phrasing the
    # set below empties and every other test here passes while asserting nothing.
    found = carve_outs
    assert_includes found, "archive-shipped",
                    "the helper docblock no longer declares archive-shipped with " \
                    "'+act+ is deliberately ABSENT'; this file's parser is now blind"
    assert_includes found, "sleeper-auction-watch",
                    "the helper docblock no longer declares sleeper-auction-watch with " \
                    "'+act+ is deliberately ABSENT'; this file's parser is now blind"
  end

  test "[unit] every act declared ABSENT is genuinely off the card, in BOTH sources" do
    helper_acts = ApplicationController.helpers.heartbeat_launchers.flat_map { |l| l[:actions] }
    view_acts   = card_action_literals
    assert_operator view_acts.size, :>=, 6, "the card's own card_actions literals did not parse"

    carve_outs.each do |act|
      assert_not_includes helper_acts, act,
                          "#{act} is documented as deliberately ABSENT but heartbeat_launchers ships it"
      assert_not_includes view_acts, act,
                          "#{act} is documented as deliberately ABSENT but tasks/_heartbeats_card's " \
                          "card_actions case ships it as a chip. The helper assertions cannot see " \
                          "this: the card overrides the helper for Carl, Avi and Steffon."
    end
  end

  test "[unit] the card's card_actions comment NAMES every act kept off the card" do
    comment = carve_out_comment
    assert_operator comment.length, :>, 200,
                    "the comment above card_actions has gone missing or been gutted"

    carve_outs.each do |act|
      assert_includes comment, act,
                      "tasks/_heartbeats_card's comment above `card_actions` does not mention " \
                      "#{act}. That comment is the first thing a developer editing chip " \
                      "membership reads, so an act kept off the card ON PURPOSE and unmentioned " \
                      "THERE reads as an oversight — and gets 'fixed'. Name it and say why."
    end
  end
end
