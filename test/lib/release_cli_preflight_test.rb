# frozen_string_literal: true

# [unit] prepare's preflight refuses before any write (task release-preflight-hardening).
# 2026-11-10's morning cycle met a half-ship card (9 repos named, PRs for 6) only at
# the coverage guard, after the assembler claim and Avi's role activity. Now the
# detection read feeds Release::Preflight first: a refusal writes nothing at all —
# no presence marker, no activity, no claim, no pin, no promote.
require_relative "release_cli_harness"

class ReleaseCliPreflightTest < ReleaseCliHarness
  def preflight_stub(unreadable: "", slots: "9")
    <<~RUBY
      ENV["RELEASE_PR_UNREADABLE"] = #{unreadable.inspect}
      ENV["RELEASE_FREE_DESK_SLOTS"] = #{slots.inspect}
      module ReleasePresence; def self.open!(**) = puts("WRITE presence"); end
      def open_role_span(*) = puts("WRITE role-span")
      def acquire_conductor_claim!(*, **) = puts("WRITE claim")
      def pin_swept_shas!(*) = puts("WRITE pin")
      def promote_accepted_to_release!(*, **) = puts("WRITE promote")
      def conductor(ruby, read_only: false)
        puts("WRITE conductor") unless read_only
        return { "tasks" => [
                   { "slug" => "half-ship", "stage" => "reviewed", "merged" => "accepted",
                     "pr_url" => "https://gh/pr/1", "repo" => "mcritchie-studio",
                     "repos" => %w[mcritchie-studio voicebox], "pr_urls" => { "mcritchie-studio" => "https://gh/pr/1" } }
                 ],
                 "release" => { "slug" => "rel-x", "state" => "assembling", "repos" => ["turf-monster"] },
                 "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      end
    RUBY
  end

  def run_prepare(stub, argv: ["--yes"], call: "prepare")
    run_cli(argv, setup: stub, call: %{begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message); end})
  end

  def test_a_half_ship_card_and_a_blind_repo_refuse_before_any_write
    out = run_prepare(preflight_stub(unreadable: "voicebox", slots: "0"))

    assert_includes out, "ABORTED", out
    assert_includes out, "release preflight refused (3)"
    assert_includes out, "member half-ship names 2 repos but has no PR for 1: voicebox"
    assert_includes out, "cannot read voicebox"
    assert_includes out, "no free desk slot"
    refute_includes out, "WRITE", "a preflight refusal must come before every write:\n#{out}"
  end

  def test_the_access_read_covers_the_active_releases_repos_too
    out = run_prepare(preflight_stub(unreadable: "turf-monster"))

    assert_includes out, "cannot read turf-monster", out
    refute_includes out, "WRITE"
  end

  def test_the_preflight_command_is_read_only_and_names_the_same_refusals
    out = run_prepare(preflight_stub(unreadable: "voicebox"), argv: [], call: "preflight")

    assert_includes out, "Release preflight — read-only"
    assert_includes out, "cannot read voicebox"
    refute_includes out, "WRITE"
  end

  def test_refreeze_runs_prepare_over_every_assembled_member
    stub = <<~'RUBY'
      def conductor(ruby, read_only: false)
        return { "release" => "rel-x", "state" => "assembled", "members" => %w[t-one t-two] } if ruby.include?("pluck(:slug)")
        raise "unexpected"
      end
      def prepare = puts("PREPARE " + opt_values("--task").join(","))
    RUBY
    out = run_prepare(stub, argv: [], call: "refreeze")

    assert_includes out, "Re-freeze rel-x: 2 assembled member(s)"
    assert_includes out, "PREPARE t-one,t-two"
  end

  def test_refreeze_refuses_with_no_assembled_member
    stub = <<~'RUBY'
      def conductor(ruby, read_only: false)
        { "release" => "rel-x", "state" => "assembling", "members" => [] }
      end
      def prepare = puts("PREPARE RAN")
    RUBY
    out = run_prepare(stub, argv: [], call: "refreeze")

    assert_includes out, "has no `assembled` member"
    refute_includes out, "PREPARE RAN"
  end
end
