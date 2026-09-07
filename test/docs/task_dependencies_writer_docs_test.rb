# frozen_string_literal: true

require "test_helper"

# Tripwire for the `dependencies` PRODUCER (/tasks/wire-task-dependencies-field).
#
# THE DEFECT THIS PINS, stated plainly: `tasks.dependencies` was a real jsonb
# column that `Release::Ordering.producer_first` really topologically sorts on —
# reached from `Release#ordered_members` and `Release::Conductor` — and it had NO
# writer through any supported surface. `grep -c dependencies bin/task` was 0, it
# was in neither permit list, and its only writers were tests calling
# `Task.create!` directly. Meanwhile FOUR documents told agents to declare it,
# two of them in a literal syntax (`dependencies: [this-task]`) that nothing
# anywhere parses. So the instruction named a behaviour nobody could perform,
# and it survived for months because prose and code were checked separately.
#
# The property under test is AGREEMENT, not wording: every doc that tells an
# agent to declare a dependency must name a command the CLI actually implements,
# and the CLI must actually implement it. Either half moving alone fails here.
class TaskDependenciesWriterDocsTest < ActiveSupport::TestCase
  BIN_TASK = Rails.root.join("bin", "task")
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read (mirrors ship_docs_sync_docs_test.rb): drop
  # * and ` and collapse whitespace so a line-wrapped phrase matches as one run.
  def norm(path)
    File.read(path).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  # Every prose site that mentions declaring a dependency. Adding a fifth without
  # adding it here is how the fifth drifts.
  DOC_SITES = [
    "config/feature_shapes.yml",
    "docs/agents/modules/modal-lifecycle.md",
    "docs/agents/modules/devops-task-board.md",
    "docs/agents/system/devops-cycle-design.md"
  ].freeze

  test "[static] bin/task implements the flag every doc points at" do
    src = File.read(BIN_TASK)
    assert_match(/TOP_LIST_FLAGS = \{ "--depends-on" => "dependencies" \}/, src,
                 "the flag the docs name must exist, or the instruction is unperformable again")
    assert_match(/TOP_LIST_FLAGS\.keys/, src,
                 "the flag must be in PARSE_FLAG_NAMES or an unknown-flag refusal swallows it")
    assert_match(/TOP_LIST_FLAGS\.each_value \{ \|col\| body\[col\] = top\[col\] if top\.key\?\(col\) \}/, src,
                 "the value must reach the request body, and by key? — a truth test drops the clear")
  end

  test "[static] dependencies is column-backed on both sides of the CLI" do
    assert_includes Task::DEVOPS_COLUMN_KEYS.keys, "dependencies",
                    "a devops write to the name must be refused, or the shadow store reopens"
    assert_match(/--depends-on/, Task::DEVOPS_COLUMN_KEYS["dependencies"],
                 "the refusal must name the command that DOES work")
    column_fields = File.read(Rails.root.join("bin", "lib", "task_column_fields.rb"))
    assert_match(/COLUMN_NAMES = %w\[[^\]]*dependencies/, column_fields,
                 "`bin/task field` resolves COLUMN_NAMES from the column; omission reinstates devops-first")
  end

  # THE REGRESSION ITSELF. `dependencies: [<something>]` was never a syntax — not
  # YAML the board reads, not a flag, not an API field name. Any doc reintroducing
  # it is describing an unperformable step, which is exactly what took months to
  # notice.
  test "[static] no doc reintroduces the unparseable declare syntax" do
    DOC_SITES.each do |rel|
      body = File.read(Rails.root.join(rel))
      refute_match(/declare\s+`?dependencies:\s*\[/i, body,
                   "#{rel} tells an agent to declare a dependency in a syntax nothing parses — " \
                   "name `bin/task update <slug> --depends-on <task-slug>` instead")
    end
  end

  # Prove the scan READ the files it claims to have checked. A guard whose input
  # never arrived passes forever and says nothing.
  test "[static] every doc site actually discusses the dependency edge" do
    DOC_SITES.each do |rel|
      body = File.read(Rails.root.join(rel))
      # `depend` and not `dependenc`: a site may legitimately speak only in the
      # flag's voice (`--depends-on`) without ever using the noun. Caught live —
      # the first draft of this guard failed on config/feature_shapes.yml for
      # exactly that reason, which is also the proof that it reads its input.
      assert_match(/depend/i, body, "#{rel} no longer mentions the dependency edge — is this list stale?")
    end
  end

  # The INVOCATION must carry the flag, not merely the file.
  #
  # This assertion started as "`--depends-on` appears somewhere in the doc" and a
  # mutation walked straight through it: renaming the flag in modal-lifecycle's
  # actual command to `--deps` left the guard green, because a nearby PROSE
  # paragraph also says `--depends-on`. The file mentioning a flag is not the
  # file INSTRUCTING with it, and only the second is what an agent copies. So
  # match `bin/task update … --depends-on` on one line, raw — norm() collapses
  # newlines and would let a flag on some other command satisfy this.
  test "[static] the two instructing sites carry the flag on the command itself" do
    %w[config/feature_shapes.yml docs/agents/modules/modal-lifecycle.md].each do |rel|
      lines = File.readlines(Rails.root.join(rel))
      instructing = lines.select { |line| line.include?("bin/task update") }
      refute_empty instructing, "#{rel} no longer carries a `bin/task update` invocation"
      assert instructing.any? { |line| line.include?("--depends-on") },
             "#{rel} instructs with `bin/task update` but not `--depends-on` — " \
             "the command an agent copies must be the one that works"
    end
  end

  # …and the flag those invocations name must be one bin/task actually parses.
  # Prose and CLI drifting apart is the whole defect; a doc naming a plausible
  # flag the parser rejects is the same failure wearing a newer word.
  test "[static] every bin/task flag the instructing sites name is parsed by the CLI" do
    parsed = File.read(BIN_TASK)
    DOC_SITES.each do |rel|
      File.readlines(Rails.root.join(rel)).each do |line|
        next unless line.include?("bin/task update")

        line.scan(/--[a-z][a-z-]+/).uniq.each do |flag|
          assert_includes parsed, "\"#{flag}\"",
                          "#{rel} names #{flag} on a bin/task command, but bin/task defines no such flag"
        end
      end
    end
  end

  # The tolerance and the refusal are a PAIR, and documenting only one is how an
  # agent concludes the wrong thing. An out-of-release dependency is fine (the
  # ordering pass skips what it cannot place); an unresolvable slug is refused,
  # precisely because that same skip makes a typo invisible.
  test "[static] the board module states both halves of the resolution rule" do
    body = norm(AGENTS.join("modules", "devops-task-board.md"))
    assert_match(/outside the release does not hold this one back/i, body,
                 "the tolerance must be stated, or the refusal reads as 'deps must be in the release'")
    # SCOPED to the phrase, not the bare word. `/replaces/i` passed page-wide on a
    # file that has said `api-devops-patch-replaces` since long before this guard —
    # so deleting BOTH in-section statements of the semantic (the `# repeatable;
    # REPLACES the list` comment and the bullet below it) left this green. That is
    # the exact defect this whole task exists to close, one assertion short: a guard
    # matching a literal string somewhere ELSE in the file reports coverage it does
    # not have. Either in-section statement satisfies it; losing both does not.
    assert_match(/replaces the list/i, body,
                 "the replace-not-append semantic bit --checks callers repeatedly")
    assert_match(/refuses a slug naming no task/i, body,
                 "the refusal must be stated beside the tolerance it exists because of")
  end
end
