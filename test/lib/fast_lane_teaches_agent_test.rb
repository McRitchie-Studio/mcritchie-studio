require "test_helper"

# [unit] Every documented fast-lane invocation must pass `--agent <soul>`.
#
# THE DEFECT THIS REPLACES A CODE FIX FOR. `--agent` sets agent_slug, which
# stamps devops.built_by, which is the ONLY input bin/reviewer-select can use to
# keep a soul off its own PR. The flag ALWAYS WORKED. No documented path passed
# it, so built_by came back blank on six consecutive tasks in one review sitting
# and the selector fails closed on every one — reviewers hand-picked their light
# and the no-self-review property went unverified.
#
# The first attempt at this task added a fourth identity source in bin/task. It
# was dead code (an unrequired constant raising NameError into its own rescue)
# and no test covered it — deleting all 40 lines left 7/7 green. The fix was
# always documentation, which is exactly why it needs a test: prose has no
# other way to fail.
class FastLaneTeachesAgentTest < ActiveSupport::TestCase
  DOCS = %w[
    docs/agents/claude.md
    docs/agents/index.md
    docs/agents/modules/building-sop.md
  ].freeze

  test "every documented bin/task begin invocation passes --agent" do
    offenders = []

    DOCS.each do |rel|
      Rails.root.join(rel).read.each_line.with_index(1) do |line, n|
        next unless line.include?("bin/task begin --title")
        # The flag may sit on this line or the wrapped continuation; scan the
        # invocation as written on the line that opens it.
        offenders << "#{rel}:#{n}" unless line.include?("--agent")
      end
    end

    assert_empty offenders,
                 "these fast-lane invocations omit --agent, so a build following them " \
                 "records no builder and reviewer-select fails closed: #{offenders.join(', ')}"
  end

  test "at least one doc explains WHY the flag matters" do
    # A flag in a command line with no reason beside it is the first thing an
    # agent drops when it paraphrases the recipe. The reason is what survives.
    explained = DOCS.any? do |rel|
      body = Rails.root.join(rel).read
      body.include?("reviewer-select") && body.include?("built_by")
    end

    assert explained, "no fast-lane doc explains why --agent is load-bearing"
  end
end
