# frozen_string_literal: true

# `bin/release qa-on-merge <slug>` (task release-sub-hour-pipeline): with the trigger on
# and no active release it runs prepare --task for that slug through the agent lane;
# otherwise it says why it did not and exits 0. Run directly:
#   ruby -Itest test/lib/release_cli_qa_on_merge_test.rb

require_relative "release_cli_harness"

class ReleaseCliQaOnMergeTest < ReleaseCliHarness
  STUB = <<~RUBY
    $ran = nil
    class ReleaseCycleDeps
      def run_step(name, argv)
        $ran = [name, argv]
        [0, ""]
      end
    end
  RUBY

  def board(slug) = %(def active_release_slug = #{slug.inspect}\n)

  def test_with_no_active_release_it_runs_a_task_scoped_prepare
    out = run_cli(["--yes"], setup: %(ENV["RELEASE_QA_ON_MERGE"] = "1"\n) + STUB + board(""),
                             call: %(s = qa_on_merge("t-fast"); puts("EXIT=" + s.to_s); puts("RAN=" + $ran.inspect)))

    assert_includes out, "starting a QA release for t-fast"
    assert_includes out, "it stops at QA"
    assert_includes out, %(RAN=["prepare", ["prepare", "--task", "t-fast", "--yes")
    assert_includes out, "EXIT=0"
  end

  def test_an_active_release_or_the_switch_off_starts_nothing
    out = run_cli(["--yes"], setup: %(ENV["RELEASE_QA_ON_MERGE"] = "1"\n) + STUB + board("rel-busy"),
                             call: %(s = qa_on_merge("t-fast"); puts("EXIT=" + s.to_s); puts("RAN=" + $ran.inspect)))
    assert_includes out, "rel-busy is active"
    assert_includes out, "RAN=nil"
    assert_includes out, "EXIT=0"

    out = run_cli(["--yes"], setup: %(ENV["RELEASE_QA_ON_MERGE"] = "0"\n) + STUB + board(""),
                             call: %(s = qa_on_merge("t-fast"); puts("RAN=" + $ran.inspect)))
    assert_includes out, "not starting a QA release — off"
    assert_includes out, "RAN=nil"
  end

  def test_an_unreadable_board_starts_nothing
    out = run_cli(["--yes"], setup: %(ENV["RELEASE_QA_ON_MERGE"] = "1"\n) + STUB +
                                    %(def conductor(*) = raise("board down")\n),
                             call: %(qa_on_merge("t-fast"); puts("RAN=" + $ran.inspect)))
    assert_includes out, "could not be read"
    assert_includes out, "RAN=nil"
  end
end
