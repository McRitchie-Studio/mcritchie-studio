# frozen_string_literal: true

# Unit tests for the desk liveness signal (lib/desk_activity.rb). Real files in a
# real tmpdir with real mtimes — this module's whole job is reading the
# filesystem, so stubbing the filesystem would test nothing.
#
#   ruby -Itest test/lib/desk_activity_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/desk_activity"

class DeskActivityTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("desk-activity")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # Write a file at `rel` and stamp its mtime `age` seconds into the past.
  def write(rel, age: 0, content: "x")
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    at = Time.now - age
    File.utime(at, at, path)
    path
  end

  def cutoff(seconds_ago)
    Time.now - seconds_ago
  end

  # --- The signal itself ----------------------------------------------------

  def test_a_freshly_written_source_file_reads_as_touched
    write("app/models/task.rb", age: 5)

    assert_equal true, DeskActivity.touched_since?(@root, cutoff(60))
  end

  def test_an_old_source_file_reads_as_untouched
    write("app/models/task.rb", age: 600)

    assert_equal false, DeskActivity.touched_since?(@root, cutoff(60))
  end

  # The case the whole module exists for: the holder is editing code and writing
  # NOTHING to the board. A board-keyed liveness rule calls this session dead; the
  # desk says, correctly, that someone is working here.
  def test_a_deep_nested_edit_counts_however_deep_it_sits
    write("app/models/task.rb", age: 9_000)
    write("test/integration/onboarding_chain_test.rb", age: 4)

    assert_equal true, DeskActivity.touched_since?(@root, cutoff(300)),
                 "one fresh file anywhere in the desk is evidence the holder is working"
  end

  # --- Pruning: machine churn is not work -----------------------------------
  #
  # Each of these directories is written by something OTHER than an agent. If any
  # of them counted, the lease would be renewed by a background process and we
  # would have rebuilt the status-line bug one indirection further out.

  def test_git_churn_alone_is_not_desk_activity
    write("app/models/task.rb", age: 9_000)
    write(".git/index", age: 1)

    assert_equal false, DeskActivity.touched_since?(@root, cutoff(300)),
                 "bin/statusline runs git on every paint — counting .git renews the lease from the status line again"
  end

  def test_server_log_and_tmp_churn_alone_is_not_desk_activity
    write("app/models/task.rb", age: 9_000)
    write("log/development.log", age: 1)
    write("tmp/pids/server.pid", age: 1)
    write("tmp/cache/bootsnap/x", age: 1)

    assert_equal false, DeskActivity.touched_since?(@root, cutoff(300)),
                 "a rails server left running is not a worker — it writes forever after its agent goes home"
  end

  def test_dependency_and_build_output_churn_alone_is_not_desk_activity
    write("app/models/task.rb", age: 9_000)
    %w[node_modules/pkg/index.js vendor/bundle/gem.rb public/assets/app.css
       coverage/index.html test-results/run.json storage/blob].each { |rel| write(rel, age: 1) }

    assert_equal false, DeskActivity.touched_since?(@root, cutoff(300)),
                 "installers and build output are written by tooling, not authored by an agent"
  end

  # Prune by RELATIVE path, so a desk (or an app file) whose name merely starts
  # with a pruned word is still counted. `log_entry.rb` is application code.
  def test_pruning_matches_directory_segments_not_name_prefixes
    write("app/models/log_entry.rb", age: 3)

    assert_equal true, DeskActivity.touched_since?(@root, cutoff(60)),
                 "app/models/log_entry.rb is authored code — only the top-level log/ directory is churn"
  end

  def test_a_desk_whose_own_name_contains_a_pruned_word_is_still_read
    nested = File.join(@root, "tmp-fix-the-thing")
    FileUtils.mkdir_p(File.join(nested, "app"))
    path = File.join(nested, "app", "thing.rb")
    File.write(path, "x")
    File.utime(Time.now, Time.now, path)

    assert_equal true, DeskActivity.touched_since?(nested, cutoff(60)),
                 "the prune list is relative to the desk root, so a desk named tmp-* is not pruned away"
  end

  # --- The third answer: nil means WE COULD NOT TELL ------------------------
  #
  # These are the cases that must never read as `false`, because `false` is the
  # answer that eventually frees someone's claim.

  def test_a_missing_root_is_unknown_not_quiet
    assert_nil DeskActivity.touched_since?(File.join(@root, "nope"), cutoff(60))
  end

  def test_a_blank_root_is_unknown_not_quiet
    assert_nil DeskActivity.touched_since?("", cutoff(60))
    assert_nil DeskActivity.touched_since?(nil, cutoff(60))
  end

  def test_a_walk_that_exhausts_its_budget_is_unknown_not_quiet
    # One more entry than the budget allows, every one of them old. A completed
    # walk would answer `false`; an ABANDONED walk must answer `nil`, because it
    # never saw the files it did not reach.
    (DeskActivity::WALK_BUDGET + 1).times { |i| write("many/f#{i}", age: 9_000) }

    assert_nil DeskActivity.touched_since?(@root, cutoff(60)),
               "an unfinished search must not be reported as a quiet desk"
  end

  # An empty desk is genuinely quiet — a completed walk that found nothing IS
  # evidence, and must not be blurred into the unknown answer.
  def test_an_empty_desk_is_quiet_not_unknown
    assert_equal false, DeskActivity.touched_since?(@root, cutoff(60))
  end

  # --- Binding the desk to the task -----------------------------------------
  #
  # Without this, the heartbeat reads whichever checkout it was launched from. The
  # primary checkout is the dangerous one: several agents write to it all day, so
  # its mtimes are always fresh and a claim judged there would renew forever.

  def test_desk_root_accepts_a_context_bound_to_this_task
    File.write(File.join(@root, ".agent-context.json"), JSON.generate("task_slug" => "my-task"))

    assert_equal @root, DeskActivity.desk_root(@root, "my-task")
  end

  def test_desk_root_refuses_a_context_bound_to_a_different_task
    File.write(File.join(@root, ".agent-context.json"), JSON.generate("task_slug" => "someone-elses-task"))

    assert_nil DeskActivity.desk_root(@root, "my-task"),
               "another task's desk says nothing about this task's holder"
  end

  def test_desk_root_refuses_a_checkout_with_no_agent_context
    assert_nil DeskActivity.desk_root(@root, "my-task"),
               "a primary checkout has no .agent-context.json — and its mtimes are every agent's, not this holder's"
  end

  def test_desk_root_refuses_an_unparseable_context
    File.write(File.join(@root, ".agent-context.json"), "{not json")

    assert_nil DeskActivity.desk_root(@root, "my-task")
  end

  # --- age_seconds: how old is this desk? -----------------------------------
  #
  # The channel the reclaim guard needs and the mtime walk cannot supply on its own.
  # A fresh worktree and a merged one are git-identical, so `cleanup --reclaim` has
  # no way to tell "nobody has written here YET" from "nobody will write here again"
  # — until it asks how old the desk is.

  # Stamp a worktree `.git` POINTER FILE (the `gitdir: …` regular file `git worktree
  # add` writes) at `age` seconds old. `write` already does the utime work.
  def write_worktree_marker(age:)
    write(".git", age: age, content: "gitdir: /repo/.git/worktrees/desk\n")
  end

  def test_age_seconds_dates_a_desk_from_its_worktree_git_marker
    write_worktree_marker(age: 7_200)

    assert_in_delta 7_200, DeskActivity.age_seconds(@root), 5
  end

  def test_a_newborn_desk_reads_as_seconds_old_not_as_unknown
    write_worktree_marker(age: 3)

    age = DeskActivity.age_seconds(@root)
    refute_nil age, "a desk created seconds ago must be DATED, not shrugged at"
    assert_operator age, :<, 60
  end

  # A `.git` DIRECTORY is a primary checkout, not a worktree desk, and its mtime is
  # not a birthday — every `git add` in it moves the directory. Answering a number
  # here would be a guess, and this module never guesses.
  def test_a_primary_checkout_git_directory_is_not_a_birthday
    FileUtils.mkdir_p(File.join(@root, ".git"))

    assert_nil DeskActivity.age_seconds(@root),
               "a .git directory is a primary checkout; its mtime says nothing about a desk's age"
  end

  def test_a_directory_with_no_git_marker_at_all_is_unknown
    assert_nil DeskActivity.age_seconds(@root),
               "no marker means we could not date it — and unknown must never read as old"
  end

  def test_a_missing_or_blank_root_is_unknown
    assert_nil DeskActivity.age_seconds(File.join(@root, "gone"))
    assert_nil DeskActivity.age_seconds("")
    assert_nil DeskActivity.age_seconds(nil)
  end

  # A marker stamped in the FUTURE (clock skew, a restored backup, a tarball with
  # bad timestamps) must not read as a negative age that then compares as "older
  # than the idle window" against every threshold. Newborn is the safe reading:
  # it KEEPS the desk.
  def test_a_future_dated_marker_reads_as_newborn_not_as_negative
    write_worktree_marker(age: -3_600)

    assert_equal 0.0, DeskActivity.age_seconds(@root),
                 "clock skew must fail toward KEEPING the desk, never toward a stale-looking negative"
  end

  def test_desk_root_accepts_any_of_the_context_slug_spellings
    %w[task_slug task worktree_slug feature].each do |key|
      File.write(File.join(@root, ".agent-context.json"), JSON.generate(key => "my-task"))

      assert_equal @root, DeskActivity.desk_root(@root, "my-task"),
                   "#{key} is a spelling bin/agent-worktree writes; all of them bind the desk"
    end
  end
end
