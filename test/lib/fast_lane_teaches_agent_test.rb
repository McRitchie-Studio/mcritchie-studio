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
  # THE DOC SET IS DERIVED, NOT LISTED — and the hand-list is why. FOUND IN
  # REVIEW: the constant here named three files, while `devops-task-board.md:479`
  # and `worktrees.md:10` BOTH documented `begin --title` with no `--agent` and
  # neither was in it. The guard passed, green and useless, while two of the docs
  # it did not read taught the exact omission this test exists to remove.
  #
  # A hand-maintained list is the same failure mode as a hand-maintained reader
  # table (see task_begin_flag_grammar_test.rb): it can only ever check what its
  # author already remembered. Deriving the set means a doc written next month is
  # covered without anyone remembering to add it.
  #
  # ARCHIVES ARE EXCLUDED on purpose: `docs/agents/archive/**` holds FROZEN
  # snapshots, not instructions, and AGENTS.md says to leave them as written. A
  # snapshot of a pre-fix doc must not be able to redden this.
  INVOCATION = "bin/task begin"
  RECIPE = "bin/task begin --title"

  def self.docs_naming_begin
    Dir.glob(Rails.root.join("docs/**/*.md")).sort
       .reject { |path| path.include?("/agents/archive/") }
       .select { |path| File.read(path).include?(INVOCATION) }
       .map { |path| Pathname.new(path).relative_path_from(Rails.root).to_s }
  end

  DOCS = docs_naming_begin.freeze

  # PROVE THE DERIVATION READ SOMETHING. A glob that matched nothing would make
  # every assertion below pass while inspecting no files at all — the quietest way
  # for this guard to die. The names pinned here are a FLOOR, not the coverage
  # list: DOCS may legitimately grow past them, and that is the point.
  test "the derived doc set actually found the docs that carry the invocation" do
    refute_empty DOCS, "the docs glob matched nothing — this guard is inspecting no files"

    # The two the old hand-list MISSED. They are pinned by name because their
    # absence is the regression, and a derivation that loses them again has
    # reintroduced it.
    assert_includes DOCS, "docs/agents/modules/devops-task-board.md"
    assert_includes DOCS, "docs/agents/modules/worktrees.md"
    # The canonical sources the projects-root CLAUDE.md / AGENTS.md generate from.
    assert_includes DOCS, "docs/agents/claude.md"
    assert_includes DOCS, "docs/agents/index.md"
  end

  test "every documented bin/task begin invocation passes --agent" do
    offenders = []

    DOCS.each do |rel|
      Rails.root.join(rel).read.each_line.with_index(1) do |line, n|
        next unless line.include?(RECIPE)
        # THE OPENING LINE MUST CARRY IT. A wrapped invocation may continue over
        # several lines, but an agent skimming for the recipe reads the line that
        # starts it — so `--agent` belongs there, not on a continuation. This is
        # stricter than checking the whole command, deliberately.
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
