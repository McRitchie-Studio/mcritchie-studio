# frozen_string_literal: true

# [unit] `bin/release ship --mode ask|timed|auto` at the ship-authority seam
# (bin/lib/ship_authority.rb), driven through the REAL `ship` in a dry-run
# subprocess: the config default is timed and previews the window, `--yes` alone
# is auto, an explicit mode wins, an unknown mode aborts before the release is
# resolved, and the two ship_authorized writes carry the keys the seam promises —
# a timed REQUEST keyed by its window end, a GRANT/completion on the default key.
# Standalone:
#   ruby -Itest test/lib/release_ship_mode_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# A NEW FILE ON PURPOSE: test/lib/release_cli_test.rb is frozen at its size by
# the suite's test-health ratchet precisely so new work lands somewhere else
# (and naming that ratchet's config file here would map this file onto it in
# the fast cert, which pins how many tests that path reaches). The harness
# below is the small one (a sealed subprocess loading the script with the ship
# conductor stubbed) rather than a copy of that file's private harness; the
# conductor stub is that file's SHIP_STUB, copied as the sibling files copy what
# they need.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseShipModeTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # Lazy + memoized so forked test workers each get their own dir, and REMOVED
  # after the run — the shape test/lib/release_cli_test.rb uses.
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-ship-mode-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # Drive bin/release.rb in a sealed subprocess: OutboundSeams puts stub binaries
  # in front of PATH (so a missed stub cannot reach the real `gh`), the conductor
  # lock dir is pinned away from the operator's live one, and the board is
  # unroutable (every board seam here is stubbed; a real call is a bug).
  def run_release(argv, setup:, call:)
    env = OutboundSeams.env(
      "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir,
      "TASK_API_BASE" => "http://127.0.0.1:1"
    )
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; #{call})
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script)
    assert status.success?, "the subprocess must catch its own abort in-process: #{out}\n#{err}"
    out
  end

  SHIP_STUB = <<~RUBY
    def conductor(ruby, read_only: false)
      return { "slug" => "rel-ship" } if ruby.include?("last_shipped") # the minimal STABLE read (pre-claim)
      return {} unless ruby.include?("repo_plan")
      { "slug" => "rel-ship", "state" => "assembled", "branch" => "release",
        "qa_shas" => {
          "studio-engine" => "aaaaaaa1111111111111111111111111111111111",
          "turf-monster" => "ccccccc3333333333333333333333333333333333",
          "mcritchie-studio" => "bbbbbbb2222222222222222222222222222222222"
        },
        "repos" => [
          { "repo" => "studio-engine", "kind" => "gem", "prod_deploy" => nil,
            "members" => [{ "slug" => "t-gem", "version" => "0.9.0", "branch" => nil }] },
          { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
            "members" => [{ "slug" => "t-turf", "version" => nil, "branch" => "feat/turf" }],
            "prod_deploy" => { "strategy" => "repo_script", "command" => "bin/deploy", "args" => ["--yes"] } },
          { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
            "members" => [{ "slug" => "t-studio", "version" => nil, "branch" => "feat/studio" }],
            "prod_deploy" => { "strategy" => "git_push_heroku", "remote" => "heroku",
                               "branch" => "main", "smoke_url" => "https://mcritchie.studio" } }
        ] }
    end
  RUBY

  # [unit] `--mode` (bin/lib/ship_authority.rb) at the ship-authority seam: the
  # config default is timed, so a bare dry-run previews the window and reads
  # nothing; `--yes` alone is auto; an unknown mode aborts before anything moves.
  def test_ship_dry_run_takes_authority_in_the_timed_default_and_previews_the_window
    out = run_release(["--dry-run"], setup: SHIP_STUB, call: "ship")

    assert_includes out, "taking production authority (--mode timed)"
    assert_includes out, "production window: 30 min"
    assert_includes out, "[dry-run] would wait up to 30 min for the grant"
    assert_includes out, "ship authority: dry (--mode timed)"
  end

  # The two ship_authorized writes as the seam records them: a timed REQUEST is
  # keyed by its window end (a re-run after a lapse refusal posts a fresh window
  # instead of the default key returning the stale one), while a GRANT/completion
  # keeps the default key so the web Approve and ship's own stamp are one row.
  RECORD_EVENT_STUB = <<~RUBY
    def record_release_event(slug, step, status, attrs = {})
      puts("EVENT \#{slug} \#{step}:\#{status} key=\#{attrs[:idempotency_key].inspect} mode=\#{attrs.dig(:metadata, "mode")}")
    end
  RUBY

  def test_ship_timed_request_is_keyed_by_its_window_end_and_the_grant_by_the_default
    out = run_release(["--dry-run"], setup: SHIP_STUB + RECORD_EVENT_STUB, call: "ship")
    assert_match(/EVENT rel-ship ship_authorized:started key="rel-ship:ship_authorized:started:20\d\d-\d\d-\d\dT[^"]+" mode=timed/, out)
    refute_match(/ship_authorized:completed/, out, "a dry timed run posts the request and completes nothing")

    out = run_release(["--dry-run", "--yes"], setup: SHIP_STUB + RECORD_EVENT_STUB, call: "ship")
    assert_includes out, "EVENT rel-ship ship_authorized:started key=nil mode=auto"
    assert_includes out, "EVENT rel-ship ship_authorized:completed key=nil mode=auto"
  end

  def test_ship_yes_alone_is_auto_and_an_explicit_mode_wins
    out = run_release(["--dry-run", "--yes"], setup: SHIP_STUB, call: "ship")
    assert_includes out, "taking production authority (--mode auto)"
    assert_includes out, "ship authority: auto (--mode auto)"

    out = run_release(["--dry-run", "--yes", "--mode", "ask"], setup: SHIP_STUB, call: "ship")
    assert_includes out, "taking production authority (--mode ask)"
    assert_includes out, "ship authority: confirmed (--mode ask)"
  end

  def test_ship_refuses_an_unknown_mode_before_anything_moves
    out = run_release(["--dry-run", "--mode", "sometimes"], setup: SHIP_STUB,
                      call: %{begin; ship; rescue SystemExit => e; puts("ABORTED: " + e.message); end})
    assert_includes out, "ABORTED: ✗ --mode must be one of ask|timed|auto, got \"sometimes\""
    refute_includes out, "shipping rel-ship", "the abort lands before the release is even resolved"
  end

end
