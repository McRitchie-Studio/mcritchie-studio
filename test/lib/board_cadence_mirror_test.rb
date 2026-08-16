require "test_helper"

# [unit] THE BEAT IS SPELLED IN THREE LANGUAGES AND MUST SAY THE SAME THING.
#
#   Ruby  — Release::BOARD_FLIP_CADENCE, seconds. The record side: the ship's member
#           flips, the archive sweep, the dev-tools Ship toy.
#   Ruby  — bin/release.rb's own BOARD_FLIP_CADENCE. A MIRROR, deliberately: the CLI
#           interpolates the number into a payload evaluated by whatever code is
#           DEPLOYED, and a live prod that predates the constant would NameError on
#           the ship it is running. So it cannot read the model's value — which is
#           exactly why it needs a guard.
#   JS    — BEAT_MS in tasks/_deployments_live_fx, milliseconds. NOT a third copy: it
#           renders from the Ruby constant, and this file holds it to that. It was a
#           copy for one day, and in that day a spec restating the old value failed as
#           though the animation were broken. Every exit animation is timed to finish
#           inside one beat, so a beat that shrank without them would put two cards on
#           screen at once, and one that grew would leave dead air.
#
# Drift here is invisible in every other test: each side is internally consistent and
# only the operator sees the mush. So the pin is asserted, not documented.
class BoardCadenceMirrorTest < ActiveSupport::TestCase
  ROOT = Rails.root

  def cli_cadence
    ROOT.join("bin/release.rb").read[/^BOARD_FLIP_CADENCE = ([\d.]+)/, 1]&.to_f
  end

  def fx_source
    ROOT.join("app/views/tasks/_deployments_live_fx.html.erb").read
  end

  def fx_constant(name)
    fx_source[/const #{name} = (\d+)/, 1]&.to_i
  end

  test "[unit] the CLI mirrors the model's cadence exactly" do
    assert_equal Release::BOARD_FLIP_CADENCE, cli_cadence,
                 "bin/release.rb's BOARD_FLIP_CADENCE must match Release::BOARD_FLIP_CADENCE"
  end

  test "[unit] the board's beat is RENDERED from the cadence, not restated" do
    assert_includes fx_source, "const BEAT_MS = <%= (Release::BOARD_FLIP_CADENCE * 1000).round %>;",
                    "the board must take the beat from Ruby — a literal here is a copy that will drift"
    assert_nil fx_constant("BEAT_MS"),
               "a numeric BEAT_MS literal means the derivation was replaced by a copy again"
  end

  test "[unit] every exit animation finishes inside one beat" do
    beat = (Release::BOARD_FLIP_CADENCE * 1000).round
    %w[EXIT_MS GAP_CLOSE_MS GROW_IN_MS SLIDE_OFF_MS].each do |name|
      duration = fx_constant(name)
      assert duration, "#{name} is missing from the live-fx partial"
      assert_operator duration, :<, beat,
                      "#{name} must finish inside the beat, or two cards animate at once"
    end
    # The MOVE is the long pole: a card leaves one column and arrives in the other
    # inside the same beat, or its arrival lands on the next card's departure.
    assert_operator fx_constant("SLIDE_OFF_MS") + fx_constant("GROW_IN_MS"), :<=, beat,
                    "slide + grow-in is one card's whole journey and must fit one beat"
  end

  test "[unit] the board publishes the beat it is playing" do
    board = ROOT.join("app/views/tasks/_deploy_board.html.erb").read
    assert_includes board, %(data-beat-ms="<%= (Release::BOARD_FLIP_CADENCE * 1000).round %>"),
                    "the e2e specs read the cadence off the board instead of restating it"
  end
end
