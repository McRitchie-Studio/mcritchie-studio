# frozen_string_literal: true

require "test_helper"
require "rake"

# [docs] A THROWAWAY DESK LACKS EVERY GITIGNORED ARTIFACT — the two hand-cut
# worktree recipes, pinned against the mechanism they now name.
#
#   bin/rails test test/docs/zap_throwaway_artifacts_docs_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT THIS CLOSES (/tasks/zap-desk-needs-build-artifacts). Measured
# 2026-09-22 while reviewing turf-monster PR #807. A reviewer cut a throwaway with
# `git worktree add --detach` and carried `.env.test.local` across, exactly as
# docs/agents/modules/zap-protocol.md told him to. The zap's own check came back
# 14 failures and 9 errors; the SAME command on the builder's desk at the SAME SHA
# came back 0. The delta was one gitignored file — app/assets/builds/tailwind.css,
# which `git worktree add` cannot carry because git does not track it.
#
# That is not a papercut, because the protocol's test rule says "a zap whose check
# fails is dead on arrival: revert it and escalate." A reviewer who follows the
# recipe exactly, sees the red, and obeys that line REVERTS A CORRECT ZAP and
# escalates a defect that does not exist. What stopped it was a baseline run on a
# tree known to be clean — luck, not procedure, until this change.
#
# TWO DOCS, ONE RECIPE. worktrees.md's mutation-pass recipe is the same four lines
# with the same gap, and it fails WORSE: an unbuilt asset there reads as a mutant
# the suite caught, which is the one wrong answer a mutation run can give. Both
# are in RECIPES below, and both are mutated in the controls — one file's red
# proves nothing about the other's.
#
# WHY THE FIX IS A CALL AND NOT A LIST. The docs could have named tailwind.css.
# They name `bin/rails test:prepare` instead — the same call
# `bin/agent-worktree#prepare_test_env` already makes for a real desk, which is why
# a `bin/agent-worktree new` desk never shows this bug. An enumerated list of
# artifacts is wrong the first time a new gitignored artifact appears; a hook is
# not. So this guard checks the CALL still does the job, never that a filename is
# spelled somewhere.
#
# WHAT EACH LANE PROVES, and lane 4's limit stated rather than implied:
#
#   1. BEHAVIOURAL. Every rake task the recipes name is a real task, and the set
#      reaches `tailwindcss:build` through the LIVE Rake graph. A gem bump that
#      moves the hook reds here, at the cause, instead of silently turning the
#      documented recipe back into the recipe that bit PR #807.
#   2. BEHAVIOURAL. The artifact the worked example rests on really is ignored by
#      THIS repo's git. If the build output is ever committed, the paragraph stops
#      being true and this says so.
#   3. STRUCTURAL. Every recipe block that carries `.env.test.local` also carries
#      the artifact step (or routes to `bin/agent-worktree new`, which does both).
#      This is the pairing a future third recipe would otherwise ship half of.
#   4. PROSE, AND ONLY PROSE. The baseline requirement must sit WITH the
#      "dead on arrival" verdict it qualifies. A guard keyed on wording is evaded
#      by rephrasing and this one is no exception — what it defends is the two
#      sentences staying CO-LOCATED, because the failure mode was a reader
#      reaching the verdict without the baseline. It cannot prove the paragraph is
#      correct English; lanes 1-3 are what carry load.
class ZapThrowawayArtifactsDocsTest < ActiveSupport::TestCase
  # Both hand-cut-worktree recipes. Adding a third belongs here, not in a copy.
  RECIPES = [
    "docs/agents/modules/zap-protocol.md",
    "docs/agents/modules/worktrees.md"
  ].freeze

  # Where the dead-on-arrival verdict lives (lane 4). Only the zap protocol states it.
  VERDICT_DOC = "docs/agents/modules/zap-protocol.md"

  # The gitignored artifact the worked example names. Asserted to BE gitignored
  # (lane 2) rather than assumed.
  BUILT_ASSET = "app/assets/builds/tailwind.css"

  # The build the prepare step must reach. tailwindcss-rails enhances
  # `test:prepare` with this; see test/lib/tasks/test_prepare_asset_hook_test.rb
  # for the whole chain and for the db:test:prepare asymmetry these docs lean on.
  BUILD_TASK = "tailwindcss:build"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("test:prepare")
  end

  test "the prepare step every throwaway recipe names really builds the gitignored asset" do
    RECIPES.each do |doc|
      tasks = rails_tasks_in_fenced_blocks(read(doc))

      refute_empty tasks,
                   "no `bin/rails <task>` step found in any fenced block of #{doc}. " \
                   "The throwaway recipe stopped naming an artifact-build step, which is " \
                   "the state that made turf-monster PR #807's zap look broken."

      tasks.each do |task|
        assert Rake::Task.task_defined?(task),
               "#{doc} tells a reader to run `bin/rails #{task}` in the throwaway, and no " \
               "such rake task exists. The recipe would die before building anything."
      end

      reached = tasks.flat_map { |task| prerequisite_closure(task) }

      assert_includes reached, BUILD_TASK,
                      "#{doc}'s throwaway recipe runs #{tasks.inspect}, and none of those " \
                      "tasks reaches #{BUILD_TASK} any more — so following it leaves " \
                      "#{BUILT_ASSET} unbuilt and every view-rendering check red on a tree " \
                      "with nothing wrong with it. Re-derive the hook (see " \
                      "test/lib/tasks/test_prepare_asset_hook_test.rb) and fix the doc."
    end
  end

  test "[unit] the artifact the worked example names is genuinely gitignored" do
    ignored = system("git", "check-ignore", "-q", BUILT_ASSET, chdir: Rails.root.to_s)

    assert ignored,
           "#{BUILT_ASSET} is no longer ignored by this repo's git, so `git worktree add` " \
           "WOULD carry it and the worked example in #{RECIPES.first} describes a problem " \
           "that has stopped existing. Re-measure the paragraph before trusting it."
  end

  test "[unit] every recipe that carries .env.test.local also carries the build step" do
    RECIPES.each do |doc|
      blocks = fenced_blocks(read(doc)).select { |block| block.include?(".env.test.local") }

      refute_empty blocks,
                   "no fenced block in #{doc} mentions .env.test.local any more; this guard " \
                   "has lost its subject there and needs re-pointing."

      blocks.each_with_index do |block, index|
        carries_step = block.include?("test:prepare") || block.include?("bin/agent-worktree new")

        assert carries_step,
               "fenced block #{index + 1} of #{doc} that mentions .env.test.local names " \
               "neither a `test:prepare` step nor `bin/agent-worktree new`. A fresh worktree " \
               "is missing TWO classes of untracked file, and a recipe that fixes only the " \
               "config half hands the reader the PR #807 failure:\n\n#{block}"
      end
    end
  end

  test "[unit] the baseline requirement sits with the dead-on-arrival verdict" do
    lines = read(VERDICT_DOC).lines
    verdict = lines.index { |line| line.include?("dead on arrival") }

    refute_nil verdict,
               "#{VERDICT_DOC} no longer states the dead-on-arrival verdict; re-point this " \
               "guard at whatever replaced it before deleting it."

    # Whitespace-normalised: the doc hard-wraps at ~78 columns, so "the same SHA"
    # lands with a newline inside it as often as not.
    window = lines[[verdict - 20, 0].max...verdict].join.downcase.gsub(/\s+/, " ")

    assert_includes window, "baseline",
                    "the dead-on-arrival verdict in #{VERDICT_DOC} has drifted away from the " \
                    "baseline requirement that qualifies it. Read alone, that verdict tells a " \
                    "reviewer to revert a correct zap over a red the throwaway caused."

    assert_includes window, "same sha",
                    "the baseline paragraph in #{VERDICT_DOC} no longer pins the comparison " \
                    "to the SAME SHA. A baseline taken at a different commit compares two " \
                    "things at once and settles nothing."
  end

  private
    def read(doc)
      File.read(Rails.root.join(doc))
    end

    # Every ```…``` block body in the markdown, fences excluded.
    def fenced_blocks(markdown)
      blocks = []
      current = nil

      markdown.each_line do |line|
        if line.start_with?("```")
          current.nil? ? current = +"" : (blocks << current; current = nil)
        elsif current
          current << line
        end
      end

      blocks
    end

    # Rake task names the fenced recipes hand to `bin/rails`. Scoped to fenced
    # blocks on purpose: the prose names `db:test:prepare` while EXPLAINING that it
    # is not the step, and a guard that swept the prose would assert the
    # counterexample it was written to rule out.
    def rails_tasks_in_fenced_blocks(markdown)
      fenced_blocks(markdown)
        .flat_map { |block| block.scan(%r{bin/rails\s+([^#)\n]+)}) }
        .flatten
        .flat_map(&:split)
        .select { |token| token.match?(/\A[a-z][a-z0-9_]*(?::[a-z0-9_]+)*\z/) }
        .uniq
    end

    # The task plus everything it pulls in, so an indirection layer between
    # `test:prepare` and the build does not read as the hook having vanished.
    def prerequisite_closure(name)
      task = Rake::Task[name]
      [name] + task.all_prerequisite_tasks.map(&:name)
    rescue StandardError
      [name] + Rake::Task[name].prerequisites
    end
end
