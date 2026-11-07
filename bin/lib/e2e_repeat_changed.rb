# frozen_string_literal: true

require "open3"

# E2eRepeatChanged — THE DETERMINISM CHECK AT THE DOOR.
#
# WHY. Alex McRitchie, 2026-11-06: "Flaky is a terrible way to describe a system." A
# spec that goes red then green at the same SHA is a defect with a cause. The cheapest
# place to find that cause is before the merge, while the author still holds the
# spec: every Playwright spec a PR adds or changes runs FIVE TIMES in the PR's own
# `playwright` lane (`--repeat-each 5`). A race the suite would hit one run in five
# turns the PR red now, instead of turning somebody else's PR red next week.
#
# WHAT IT RUNS. The PR's merge commit (what `pull_request` checks out) against its
# first parent, the base tip: the specs under e2e/ the PR added, changed or renamed,
# minus any it deleted. No spec changed, or not a pull request: it says so and runs
# nothing. Each shard runs its share (Playwright's own --shard over the repeats), so
# the check costs the lane a few repeats per shard, not five extra runs of one shard.
#
# IT NEVER NARROWS THE SUITE. It runs in its own step after the whole-suite step, with
# the list reporter only, so it writes no executed-set receipt and cannot change what
# e2e_executed_set judges. Guard: test/lib/e2e_repeat_changed_test.rb.
module E2eRepeatChanged
  REPEATS = 5
  SPEC = %r{\Ae2e/.+\.spec\.js\z}

  module_function

  # PURE. `git diff --name-status` lines → the specs to repeat, sorted.
  # "M\te2e/a.spec.js", "A\te2e/b.spec.js", "R100\te2e/old.spec.js\te2e/new.spec.js", "D\t…".
  def changed_specs(name_status)
    name_status.to_s.each_line.filter_map do |line|
      status, *paths = line.chomp.split("\t")
      next if status.to_s.start_with?("D")

      path = paths.last.to_s
      path if path.match?(SPEC)
    end.uniq.sort
  end

  # PURE. The Playwright command for the specs, or nil when there are none.
  def command(specs, shard: nil)
    return nil if specs.empty?

    # @quarantine stays out exactly as it does in the suite step: a quarantined spec is
    # already known red, and repeating it proves nothing new.
    cmd = ["npx", "playwright", "test", *specs, "--repeat-each", REPEATS.to_s, "--grep-invert", "@quarantine", "--reporter=list"]
    cmd << "--shard=#{shard}" if shard
    cmd
  end

  # The diff the PR brings, read from the merge commit's first parent. A shallow
  # checkout holds one commit, so the parent is fetched first (by SHA, as GitHub allows).
  def name_status(env: ENV, run: method(:capture))
    return nil unless env["GITHUB_EVENT_NAME"].to_s.start_with?("pull_request")

    sha = env.fetch("GITHUB_SHA", "HEAD")
    run.call(["git", "fetch", "--no-tags", "--depth=2", "origin", sha])
    out, ok = run.call(["git", "diff", "--name-status", "-M", "#{sha}^1", sha])
    ok ? out : nil
  end

  def capture(argv)
    out, _err, status = Open3.capture3(*argv)
    [out, status.success?]
  end
end
