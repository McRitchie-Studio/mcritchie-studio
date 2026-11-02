require "test_helper"

# [unit] THE BEAT IS SPELLED IN THREE LANGUAGES AND MUST SAY THE SAME THING.
#   Ruby: Release::BOARD_FLIP_CADENCE, seconds. The record side.
#   Ruby: bin/release.rb's BOARD_FLIP_CADENCE, a deliberate MIRROR: the payload runs on DEPLOYED
#         code, and a prod predating the constant would NameError.
#   JS:   app/javascript/board/live_fx exit timings; data-beat-ms comes from the Ruby constant
#         and e2e/deployments_exit_fx.spec.js asks exceedsBeat.
# Drift is invisible elsewhere. data-beat-ms: test/integration/last_release_fx_router_test.rb.
# History: task stagger-board-exit-animations.
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
