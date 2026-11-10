# frozen_string_literal: true

# [unit] Re-freeze an assembled release after a fix lands on `release` (task
# release-prepare-night-lessons).
#
# rel-20261110-208612: an empty commit went onto voicebox `release` to clear a CDN red.
# `release prepare --task system-tests-reset-window-size` refused it ("not sweepable":
# the task was an `assembled` member, no sweep candidate), and a plain `release prepare`
# swept every reviewed task and stopped on another repo's red `accepted`. qa_shas was
# re-recorded only by naming an unrelated still-`reviewed` task. Now --task takes an
# assembled member of the active release: no promote, no new pin, and the QA deploy and
# qa_shas record read each repo's moved `release` tip.
require_relative "release_cli_harness"

class ReleaseCliRefreezeTest < ReleaseCliHarness
  MOVED_TIP = "ee2f7cf0000000000000000000000000000000aa"

  def refreeze_stub
    stale_tree_stub(ahead: 0) + %(MOVED_TIP = #{MOVED_TIP.inspect}\n) + <<~'RUBY'
      alias tree_sh sh
      def sh(*a, **k)
        return [MOVED_TIP, true] if a[0] == "git" && a.include?("rev-parse") && a.last.to_s == "origin/release"
        tree_sh(*a, **k)
      end
      def conductor(ruby, read_only: false)
        if ruby.include?("sweep_candidates")
          return { "tasks" => [
                     { "slug" => "t-member", "stage" => "assembled", "refreeze" => true, "merged" => "release",
                       "pr_url" => "https://gh/pr/7", "repo" => "mcritchie-studio", "repos" => ["mcritchie-studio"],
                       "pr_urls" => { "mcritchie-studio" => "https://gh/pr/7" }, "release_slug" => "rel-strand" }
                   ],
                   "release" => { "slug" => "rel-strand", "state" => "assembled" },
                   "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
        end
        puts("SWEEP-CALL") if ruby.include?("sweep!")
        puts("QA-SHAS " + ruby[/shas: (\{[^}]*\})/, 1].to_s) if ruby.include?("record_qa_shas")
        return { "state" => "assembled" } if ruby.include?("qa_green!")
        { "slug" => "rel-strand", "state" => "assembled", "branch" => "release", "repos" => [
          { "repo" => "mcritchie-studio", "kind" => "app", "release_branch" => "release",
            "qa_app" => "mcritchie-studio", "members" => [{ "slug" => "t-member", "branch" => "feat/m" }] }
        ] }
      end
    RUBY
  end

  def test_an_assembled_member_re_records_the_moved_release_tip_without_a_promote
    out = run_cli(["--yes", "--task", "t-member"], setup: refreeze_stub,
                  call: %{begin; prepare; rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    refute_includes out, "not sweepable", out
    refute_includes out, "ABORTED", out
    assert_includes out, "re-freeze t-member: an assembled member of rel-strand"
    refute_includes out, "promote accepted → release", "a re-freeze lands nothing from accepted"
    refute_includes out, "SWEEP-CALL", "the member is already on the release; no sweep! write"
    assert_includes out, "QA-DEPLOY", "QA re-deploys the release tip"
    shas = out[/^QA-SHAS (.*)$/, 1]
    refute_nil shas, "qa_shas is re-recorded: #{out}"
    assert_includes shas, MOVED_TIP, "the frozen SHA is the moved `release` tip"
  end
end
