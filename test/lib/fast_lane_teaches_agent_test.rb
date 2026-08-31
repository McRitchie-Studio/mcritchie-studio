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
  # `--title` is what makes a documented line a CREATE, and a create is the form
  # that stamps a builder. `bin/task begin <slug>` is the RESUME form and prose
  # like "`bin/task begin` runs steps 1-2" is not an invocation at all; neither
  # can carry a builder to stamp, so neither is an offender.
  CREATE_FLAG = "--title"

  # MATCHED BY CONTENT, NEVER BY FLAG ORDER. This was one concatenation —
  # `"bin/task begin --title"` — so the scan only fired on lines that happened to
  # spell the flags in that order. MEASURED: rewriting `devops-task-board.md` so
  # `--repo` precedes `--title`, with no `--agent` anywhere on the line, passed
  # the whole guard clean. A documented invocation bought an exemption by
  # rearranging its own flags, and the doc that taught the omission read as
  # covered. The two markers are now tested independently.
  def self.create_invocation?(line)
    line.include?(INVOCATION) && line.include?(CREATE_FLAG)
  end

  # THE SCAN AS A FUNCTION OF TEXT, so the tests below can drive the real matcher
  # over a synthetic doc instead of mutating a file on disk. A guard that can only
  # read the repo can only ever assert that the repo is currently clean — it can
  # never show WHICH breakages it would catch.
  def self.offenders_in(body, rel)
    body.each_line.with_index(1).filter_map do |line, n|
      next unless create_invocation?(line)
      # THE OPENING LINE MUST CARRY IT. A wrapped invocation may continue over
      # several lines, but an agent skimming for the recipe reads the line that
      # starts it — so `--agent` belongs there, not on a continuation. This is
      # stricter than checking the whole command, deliberately.
      next if line.include?("--agent")

      "#{rel}:#{n}"
    end
  end

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
    offenders = DOCS.flat_map { |rel| self.class.offenders_in(Rails.root.join(rel).read, rel) }

    assert_empty offenders,
                 "these fast-lane invocations omit --agent, so a build following them " \
                 "records no builder and reviewer-select fails closed: #{offenders.join(', ')}"
  end

  # [integration] THE REORDER ESCAPE, FROZEN. The measured hole: flags spelled in
  # a different order slipped the concatenation the scan matched on, so a
  # documented create invocation with NO `--agent` passed clean.
  test "an invocation that omits --agent is caught whatever order its flags are in" do
    body = <<~MD
      Start the session:

      ```bash
      bin/task begin --repo mcritchie-studio --title "Three To Five Words" --shape backend
      ```
    MD

    # PROVE THE HAZARD IS PRESENT. If the fixture happened to spell the old
    # concatenation, the previous matcher would have caught it too and this test
    # would say nothing about flag order.
    refute_includes body, "bin/task begin --title",
                    "the fixture must NOT spell the old concatenation, or it exercises nothing"

    assert_equal ["docs/fixture.md:4"], self.class.offenders_in(body, "docs/fixture.md"),
                 "a reordered create invocation missing --agent must still be reported"
  end

  # [unit] THE COUNTERPART, so the matcher above is not simply flagging everything.
  # A guard that reports every line is as useless as one that reports none, and
  # from the assertion alone the two look identical.
  test "the matcher spares the resume form, prose, and a compliant invocation" do
    spared = [
      %(bin/task begin --repo mcritchie-studio --title "Three To Five Words" --agent avi),
      "bin/task begin <task-slug>        # resume a partial begin",
      "`bin/task begin` runs steps 1-2 (create → worktree → bind → `move building`)",
      %(bin/ship <task-slug> -m "msg"  # not begin at all, despite the --title below)
    ]

    spared.each do |line|
      assert_empty self.class.offenders_in(line, "docs/fixture.md"),
                   "this line must not be reported as an offender: #{line.inspect}"
    end

    refute self.class.create_invocation?("bin/task begin <task-slug>"),
           "the resume form carries no builder to stamp and is not a create invocation"
    assert self.class.create_invocation?(%(bin/task begin --repo x --title "y")),
           "a create invocation is a create invocation in any flag order"
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
