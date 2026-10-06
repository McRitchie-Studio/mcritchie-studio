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
#   JS    — the board's exit timings (app/javascript/board/live_fx). The board
#           PUBLISHES the beat as data-beat-ms, rendered from the Ruby constant, and
#           the live-board e2e (e2e/deployments_exit_fx.spec.js) reads it there and
#           asks the module whether every exit fits it (exceedsBeat). A beat that
#           shrank without the exits would put two cards on screen at once.
#
# Drift here is invisible in every other test: each side is internally consistent and
# only the operator sees the mush. So the pin is asserted, not documented. The board's
# data-beat-ms is held in test/integration/last_release_fx_router_test.rb.
class BoardCadenceMirrorTest < ActiveSupport::TestCase
  ROOT = Rails.root

  def cli_cadence
    ROOT.join("bin/release.rb").read[/^BOARD_FLIP_CADENCE = ([\d.]+)/, 1]&.to_f
  end

  test "[unit] the CLI mirrors the model's cadence exactly" do
    assert_equal Release::BOARD_FLIP_CADENCE, cli_cadence,
                 "bin/release.rb's BOARD_FLIP_CADENCE must match Release::BOARD_FLIP_CADENCE"
  end
end
