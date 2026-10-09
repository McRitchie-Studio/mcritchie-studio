# frozen_string_literal: true

# The release lane in the bin/release CLI: `bin/release status` prints the lane
# sentences the board serves (who is assembling, who is shipping, what the
# production grant covers), and a second session's prepare seam prints the holder
# before it stands down. The sentences are the Next Release card's own
# (Release::LaneLease); test/integration/release_status_lane_test.rb runs the loop
# against a real board.
#
# Part of the bin/release CLI suite; the shared subprocess harness lives in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_lane_lease_test.rb

require_relative "release_cli_harness"

class ReleaseCliLaneLeaseTest < ReleaseCliHarness
  LANE = [
    "Mawile (steffon, session …9b57) is assembling rel-cli since Oct 8, 01:30 UTC.",
    "Nobody is shipping rel-cli.",
    "Approved by Alex McRitchie at Oct 8, 01:35 UTC, timed mode.",
    "Covers every task on this release when it ships: 6 at approval, 16 now."
  ].freeze

  # A clean ladder whose board read also serves `lane`.
  def lane_stub(lane)
    <<~RUBY
      def conductor(ruby, read_only: false)
        { "pending" => [], "accepted" => [], "lane" => #{lane.inspect},
          "release" => { "slug" => "rel-cli", "state" => "assembling" } }
      end
      def ladder_ahead_states
        { "release" => [{ "repo" => "mcritchie-studio", "ahead" => 0 }],
          "accepted" => [{ "repo" => "mcritchie-studio", "ahead" => 0 }], "unreadable" => [] }
      end
    RUBY
  end

  def test_status_prints_the_lane_sentences_the_board_serves_under_the_current_release
    out = run_cli(["status"], setup: lane_stub(LANE), call: "status")

    release_at = out.index("current release: rel-cli (assembling)")
    refute_nil release_at
    LANE.each do |line|
      at = out.index("    #{line}")
      refute_nil at, "status prints the board's sentence verbatim: #{line}"
      assert_operator at, :>, release_at, "the lane sits under the release it describes"
    end
  end

  def test_status_control_a_board_that_serves_no_lane_prints_none
    out = run_cli(["status"], setup: lane_stub(nil), call: "status")

    assert_includes out, "current release: rel-cli (assembling)"
    refute_includes out, "is assembling"
    refute_includes out, "Covers every task"
  end

  def test_status_asks_the_board_for_the_lane_in_the_same_single_read
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        puts("READ-ONLY=\#{read_only}")
        puts("SNIPPET=\#{ruby}")
        { "pending" => [], "accepted" => [], "release" => nil }
      end
      def ladder_ahead_states = { "release" => [], "accepted" => [], "unreadable" => [] }
    RUBY
    out = run_cli(["status"], setup: setup, call: "status")

    assert_equal 1, out.scan("SNIPPET=").size, "one board read, so the prod connection budget is unchanged"
    assert_includes out, "READ-ONLY=true"
    assert_includes out, "Release::LaneLease.status_lines(r)"
    assert_includes out, "lane: lane"
  end

  # A second session's prepare stands down WITH THE HOLDER NAMED. The real
  # conductor_claim seam runs here against a stand-in claim CLI that answers as the
  # board does for a held release (the holder's lane sentence, exit 10), so this
  # pins that the sentence reaches the release log before the abort.
  def test_a_second_sessions_prepare_seam_prints_the_holder_then_stands_down
    sentence = "Mawile (steffon, session …9b57) is assembling rel-x since Oct 8, 01:30 UTC."
    Dir.mktmpdir do |dir|
      stand_in = File.join(dir, "claim_cli.rb")
      File.write(stand_in, <<~RUBY)
        puts("release-claim: 🛑 rel-x assembler already held — STAND DOWN.")
        puts("  #{sentence}")
        exit(10)
      RUBY
      out = run_cli([], setup: %(Object.send(:remove_const, :RELEASE_CLAIM_CLI); RELEASE_CLAIM_CLI = #{stand_in.inspect}),
                    call: %(begin; acquire_conductor_claim!("assembler", "rel-x"); puts("NO-ABORT"); ) +
                          %(rescue SystemExit; puts("ABORTED COUNT=" + held_conductor_claims.size.to_s); end))

      assert_includes out, "    #{sentence}", "the holder's sentence is echoed into the release log"
      assert_operator out.index(sentence), :<, out.index("ABORTED COUNT=0"), "named before the run stands down"
      refute_includes out, "NO-ABORT"
    end
  end

  # Control for the seam above: a free claim prints no holder and records the claim.
  def test_control_a_free_claim_does_not_stand_down
    Dir.mktmpdir do |dir|
      stand_in = File.join(dir, "claim_cli.rb")
      File.write(stand_in, %(puts("release-claim: ✅ rel-x assembler claimed"); exit(0)\n))
      out = run_cli([], setup: %(Object.send(:remove_const, :RELEASE_CLAIM_CLI); RELEASE_CLAIM_CLI = #{stand_in.inspect}),
                    call: %(begin; acquire_conductor_claim!("assembler", "rel-x"); puts("HELD COUNT=" + held_conductor_claims.size.to_s); ) +
                          %(rescue SystemExit; puts("ABORTED"); end))

      assert_includes out, "HELD COUNT=1"
      refute_includes out, "ABORTED"
    end
  end
end
