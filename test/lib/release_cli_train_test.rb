# frozen_string_literal: true

# `bin/release --train <slug>` (release-trains-design.md §2, task B): the dry-run
# prepare on an app train sweeps only that train's tasks and promotes only its repos;
# the hub run holds the app train's tasks; with no --train every snippet the CLI sends
# the board is the hub's pre-train Ruby; and an app train refuses to promote a repo
# whose `accepted` carries a hub-train task's merge.
#
# Part of the bin/release CLI suite, one file per subcommand. The shared subprocess
# harness lives in test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_train_test.rb

require_relative "release_cli_harness"

class ReleaseCliTrainTest < ReleaseCliHarness
  # Three reviewed candidates on `accepted`: a turf-only task (turf-monster train), a
  # hub task, and an app-plus-engine task (hub train). Every snippet sent is echoed as
  # a SENT line so the test can read what the board would evaluate.
  TRAIN_STUB = <<~'RUBY'
    def conductor(ruby, read_only: false)
      $stdout.puts("SENT " + train_guarded(ruby))
      if ruby.include?("sweep_candidates")
        mk = lambda do |slug, repos|
          { "slug" => slug, "stage" => "reviewed", "merged" => "accepted", "kind" => "app",
            "pr_url" => "https://github.com/McRitchie-Studio/#{repos.first}/pull/1", "repo" => repos.first, "repos" => repos,
            "pr_urls" => repos.to_h { |r| [ r, "https://github.com/McRitchie-Studio/#{r}/pull/1" ] } }
        end
        { "tasks" => [ mk.call("turf-only", [ "turf-monster" ]), mk.call("hub-task", [ "mcritchie-studio" ]),
                       mk.call("turf-engine", %w[turf-monster studio-engine]) ],
          "release" => nil,
          "screen" => { "rows" => [], "blocked" => [], "overridden" => [], "missing" => [], "proceed" => true } }
      else
        {}
      end
    end
  RUBY

  def promoted_repos(out)
    out.scan(/^→ promote accepted → release in (\S+):/).flatten
  end

  def test_turf_train_dry_run_sweeps_and_promotes_only_turf
    out = run_cli(["--dry-run", "--train", "turf-monster"], call: "prepare", setup: TRAIN_STUB)

    assert_includes out, "· turf-monster train"
    assert_equal [ "turf-monster" ], promoted_repos(out), "only the train's own repo is promoted"
    assert_includes out, "⚠ HELD hub-task: rides the hub train"
    assert_includes out, "⚠ HELD turf-engine: rides the hub train", "app plus engine rides the hub"
    refute_includes out, "⚠ HELD turf-only"
    assert_includes out, "1 task(s) would sweep"
    assert_includes out, 'Release::Conductor.sweep_candidates(train: "turf-monster")'
    assert_includes out, 'r = Release.current("turf-monster")'
    assert_includes out, "guard: would check `accepted` in turf-monster carries only turf-monster-train work"
  end

  def test_turf_train_snippets_carry_the_board_guard
    out = run_cli(["--dry-run", "--train", "turf-monster"], call: "prepare", setup: TRAIN_STUB)

    sent = out.lines.grep(/\ASENT /)
    refute_empty sent
    sent.each do |line|
      assert line.start_with?("SENT raise 'the production board predates release trains"),
             "every turf-train snippet first proves the board can route trains: #{line}"
    end
  end

  def test_hub_dry_run_holds_the_turf_only_task_and_sends_pre_train_ruby
    out = run_cli(["--dry-run"], call: "prepare", setup: TRAIN_STUB)

    assert_includes out, "⚠ HELD turf-only: rides the turf-monster train"
    assert_includes out, "`bin/release prepare --train turf-monster`"
    assert_equal %w[mcritchie-studio turf-monster studio-engine], promoted_repos(out),
                 "the hub promotes the repos its own members name, the app-plus-engine turf half included"
    assert_includes out, "2 task(s) would sweep"
    refute_includes out, "train:", "a hub run sends no train keyword the deployed board may not know"
    refute_includes out, "predates release trains", "a hub run sends no train guard"
    refute_includes out, "Release.current(", "a hub run reads the bare Release.current"
    assert_includes out, "c = Release::Conductor.sweep_candidates; "
  end

  # The hub's write snippets are the pre-train strings, verbatim.
  def test_hub_sweep_write_snippets_are_unchanged
    expected = "result = Release.transaction { slugs = [\"a\"]; " \
               "slugs.each { |s| Release::Conductor.sweep!(Task.find_by!(slug: s)) }; " \
               "r = Release.current_or_open!; " \
               "Release::Conductor.validate_members!(r); " \
               "{ slug: r.slug, state: r.state, swept: slugs, repos: Release::Conductor.repo_plan(r) } }; " \
               "puts(result.to_json)"
    assert_equal expected, eval_with_argv([], %(batch_sweep_with_plan_ruby(["a"])))
    assert_equal "abc", eval_with_argv([], %(train_guarded("abc")))
    assert_equal "__forming__", eval_with_argv([], "forming_slug"), "the hub keeps the bare sentinel"
  end

  def test_turf_sweep_write_snippet_names_the_train
    ruby = eval_with_argv(["--train", "turf-monster"], %(batch_sweep_with_plan_ruby(["a"], "rel-x")))
    assert_includes ruby, 'Release.open!(slug: "rel-x", train: "turf-monster") if Release.current("turf-monster").nil?'
    assert_includes ruby, 'Release::Conductor.sweep!(Task.find_by!(slug: s), train: "turf-monster")'
    assert_includes ruby, 'r = Release.current_or_open!("turf-monster")'
    assert_equal "__forming__:turf-monster", eval_with_argv(["--train", "turf-monster"], "forming_slug")
  end

  def test_unknown_or_bare_train_is_refused_before_dispatch
    status = ->(argv) { eval_with_argv(argv, "begin; refuse_bad_train!; 'ran'; rescue SystemExit => e; e.status; end") }
    assert_equal "1", status.call(["--train", "nope"])
    assert_equal "1", status.call(["--train"])
    assert_equal "ran", status.call(["--train", "turf-monster"])
    assert_equal "ran", status.call([])
  end

  # [integration] The app-train accepted guard, live (no --dry-run): turf's `accepted`
  # carries a merge from an app-plus-engine task, which rides the hub, so the turf
  # train refuses before the promote.
  def foreign_stub(log)
    <<~RUBY
      def repo_path(_repo) = #{self.class.stub_repo.inspect}
      def sh(*a, **k)
        return [#{log.inspect}, true] if a[0] == "git" && a.include?("log")
        ["", true]
      end
      def conductor(ruby, read_only: false)
        { "tasks" => { "turf-only" => ["turf-monster"], "turf-engine" => ["turf-monster", "studio-engine"] } }
      end
    RUBY
  end

  def foreign_guard(log)
    run_cli(["--train", "turf-monster"], setup: foreign_stub(log),
            call: "begin; refuse_foreign_accepted_work!; puts 'PASSED'; rescue SystemExit => e; puts 'ABORT ' + e.message.to_s; end")
  end

  def test_hub_task_merge_on_turf_accepted_blocks_the_turf_train
    out = foreign_guard("aaa1111 Merge pull request #9 from McRitchie-Studio/feat/turf-only\n" \
                        "bbb2222 Merge pull request #10 from McRitchie-Studio/feat/turf-engine\n")

    assert_includes out, "ABORT ✗ prepare --train turf-monster refused"
    assert_includes out, "turf-engine (hub train, turf-monster bbb2222)"
    refute_includes out, "turf-only (", "the train's own task is not named"
    refute_includes out, "PASSED"
  end

  def test_only_turf_train_merges_on_accepted_pass_the_guard
    out = foreign_guard("aaa1111 Merge pull request #9 from McRitchie-Studio/feat/turf-only\n")

    assert_includes out, "carries only turf-monster-train task merges (turf-only)"
    assert_includes out, "PASSED"
  end
end
