# frozen_string_literal: true

require "test_helper"

# GUARD (guard-credential-rotation-invocable, 2026-09-09): the `credential-rotation`
# SOP is the procedure Mr. McRitchie follows during a full credential rotation. Two
# properties decide whether it is INVOCABLE AT ALL, and neither is visible from
# reading the file:
#
#   REGISTERED — an SOP absent from the registry is not an SOP. An agent told
#     "credential-rotation" resolves the phrase through the tables in
#     docs/agents/index.md; miss one table and the failure is SILENT (the agent
#     treats the invocation as ordinary prose and improvises). docs/agents/claude.md
#     is the file Claude Code AUTO-LOADS, so an SOP it never names is the one Claude
#     is least likely to resolve.
#
#   STANDALONE — AGENTS.md's SOP Invocation Standard: "every command, gate and
#     decision rule is inline," and an SOP may reference only (1) other REGISTERED
#     SOPs at composition seams, (2) a registered shared primitive, one hop, and
#     (3) an explicitly marked "Background — not needed to execute" section. A
#     required hop to an UNREGISTERED file is how a self-contained procedure quietly
#     becomes a two-file scavenger hunt — and the reader who discovers that is
#     mid-rotation, with a credential already half-dead.
#
# ── WHY NOT GREP THE PROSE ────────────────────────────────────────────────────
#
# The tempting guard is a keyword list — assert the SOP says "rollback", says
# "digest", says "Dependabot". It is worthless. Those words survive any rewording
# that guts the procedure: a file can say "rollback" in a sentence that no longer
# tells you where the point of no return is, and the guard stays green. Worse, it
# fails the other way too, reddening on a legitimate rewrite that says the same
# thing better. Prose quality is what a REVIEWER reads for. What a test can hold is
# STRUCTURE: the row exists, the path resolves, the hops are legal.
#
# ── WHY EVERY COUNT HAS A FLOOR ───────────────────────────────────────────────
#
# Four times this cycle a sweep passed having proved nothing, because its selector
# stopped matching and an assertion over an empty set is vacuously true. Every scan
# below therefore asserts a FLOOR on what it swept before it grades anything.
class CredentialRotationSopDocsTest < ActiveSupport::TestCase
  DOCS_ROOT = Rails.root.join("docs/agents")
  INDEX     = DOCS_ROOT.join("index.md")
  CLAUDE    = DOCS_ROOT.join("claude.md")

  INVOCATION = "credential-rotation"
  SOP_PATH   = "docs/agents/agents/steffon/sops/credential-rotation.md"
  SOP        = Rails.root.join(SOP_PATH)

  # Same row shape the registry uses (see sop_registry_docs_test.rb). The name class
  # admits spaces and capitals so the `Steffon Heartbeat` rows are counted too —
  # they are part of the floor that proves this regex still sees the tables.
  ROW = /^\|\s*`([A-Za-z0-9][A-Za-z0-9 -]*)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

  # Markdown links only. A backticked path is deliberately NOT a hop: it routes a
  # reader without making the SOP depend on the file resolving, which is exactly
  # what docs-maintenance recommends for a target that may move. Links are the
  # references that make a claim about another file, so links are what is graded.
  LINK = /\]\(([^)\s]+\.md)\)/

  # The heading that opens the section the standalone rule exempts.
  BACKGROUND_HEADING = "## Background — not needed to execute"

  # ── The declared exceptions, with reasons ─────────────────────────────────
  #
  # A link in the executable body may point at an UNREGISTERED file only when the
  # SOP WRITES to it rather than reading a procedure out of it. Those two are not
  # the same dependency: the SOP inlines the row format it appends, so a reader who
  # never opens either file can still execute Phase 7. Carried as a named list
  # rather than waved through, and re-checked below so it cannot rot into a place
  # where a real hop hides.
  WRITE_TARGETS = {
    "docs/agents/system/secrets-rotation.md" =>
      "Phase 7 APPENDS the receipt row to its Rotation log; the row format is inline in the SOP",
    "docs/agents/modules/credential-inventory.md" =>
      "Phase 7 UPDATES an item row there when a recorded fact changed; the SOP states which facts"
  }.freeze

  def registry_rows(text)
    text.lines.filter_map do |line|
      m = ROW.match(line)
      next unless m

      { invocation: m[1], owner: m[2].strip, path: m[3] }
    end
  end

  # The registry is printed TWICE — the top-level table and the reference section —
  # and an agent may read either one. Split on the reference heading so each half is
  # graded on its own; a name in one table and not the other is a coin flip.
  def registry_halves
    text = INDEX.read
    heading = text.index("## SOP Registry")
    refute_nil heading, "docs/agents/index.md lost its '## SOP Registry' reference section"

    [registry_rows(text[0...heading]), registry_rows(text[heading..])]
  end

  def sop_body
    @sop_body ||= SOP.read
  end

  # Everything before the Background heading. This is the part a soul executes, and
  # the part whose hops must be legal.
  def executable_body
    idx = sop_body.index(BACKGROUND_HEADING)
    refute_nil idx,
               "the SOP lost its '#{BACKGROUND_HEADING}' heading. That heading is what makes the " \
               "standalone rule checkable — it is where a reference that is neither registered nor " \
               "a write target is allowed to live. Without it this test cannot tell an execution " \
               "hop from a footnote."
    sop_body[0...idx]
  end

  # Link targets are relative to the SOP's own directory. Returned as repo-relative
  # paths so they compare directly against registry rows.
  def links_in(text)
    text.scan(LINK).flatten.map do |target|
      SOP.dirname.join(target).cleanpath.relative_path_from(Rails.root).to_s
    end.uniq
  end

  # ── REGISTERED ────────────────────────────────────────────────────────────

  test "credential-rotation is registered in BOTH index.md tables, owned by Steffon, and resolves" do
    top, reference = registry_halves

    # The floor first. A regex that stopped matching would make every assertion
    # below pass on an empty corpus.
    assert_operator top.length, :>=, 25,
                    "only #{top.length} rows parsed from the top-level registry table — the ROW " \
                    "regex has gone blind and the assertions below would grade nothing"
    assert_operator reference.length, :>=, 25,
                    "only #{reference.length} rows parsed from the '## SOP Registry' reference " \
                    "table — the ROW regex has gone blind"

    [["top-level", top], ["reference", reference]].each do |name, rows|
      row = rows.find { |r| r[:invocation] == INVOCATION }

      refute_nil row,
                 "`#{INVOCATION}` has no row in the #{name} SOP registry table in docs/agents/index.md. " \
                 "An agent told to run it would treat the invocation as ordinary prose and improvise."
      assert_equal "Steffon", row[:owner], "#{name} table names the wrong owner for `#{INVOCATION}`"
      assert_equal "mcritchie-studio/#{SOP_PATH}", "mcritchie-studio/#{row[:path]}",
                   "#{name} table points `#{INVOCATION}` at the wrong file"
    end

    assert_path_exists SOP, "the registry names #{SOP_PATH}, which does not exist on disk"
  end

  # Claude Code auto-loads docs/agents/claude.md. The adapter abbreviates the
  # registry on purpose, so this asserts PRESENCE of this one invocation rather
  # than set equality — and asserts the anchor it scopes to, because a scan whose
  # anchor moved would check nothing while staying green.
  test "the Claude adapter names credential-rotation in its SOP-invocation sentence" do
    body = CLAUDE.read
    anchor = body.index("resolve that phrase")

    refute_nil anchor,
               "docs/agents/claude.md no longer contains the 'resolve that phrase' SOP-invocation " \
               "anchor this scan scopes to — without it the assertion below checks NOTHING"

    named = body[0..anchor].scan(/`([a-z0-9][a-z0-9-]*-[a-z0-9-]*)`/).flatten.uniq

    assert_operator named.length, :>=, 5,
                    "the adapter's SOP sentence names only #{named.length} invocations — it was " \
                    "reworded past recognition, or this scan has stopped seeing them"
    assert_includes named, INVOCATION,
                    "docs/agents/claude.md does not name `#{INVOCATION}`. It is the file Claude Code " \
                    "auto-loads; an SOP it never names is the one Claude is least likely to resolve."
  end

  # ── STANDALONE ────────────────────────────────────────────────────────────

  test "every doc the credential-rotation SOP links resolves on disk" do
    targets = links_in(sop_body)

    assert_operator targets.length, :>=, 3,
                    "only #{targets.length} markdown links found in the SOP — the LINK regex has gone " \
                    "blind and the assertion below would grade an empty set"

    missing = targets.reject { |t| Rails.root.join(t).exist? }

    assert_empty missing,
                 "the SOP points at files that do not exist: #{missing.inspect}. A displaced pointer " \
                 "in a rotation runbook strands its reader mid-rotation."
  end

  test "every hop in the executable body is a registered SOP or a declared write target" do
    registered = registry_halves.first.map { |r| r[:path] }.to_set
    hops = links_in(executable_body)

    assert_operator hops.length, :>=, 2,
                    "only #{hops.length} links found in the SOP's executable body — either the section " \
                    "split or the LINK regex stopped matching, and this assertion would pass on nothing"

    illegal = hops.reject { |h| registered.include?(h) || WRITE_TARGETS.key?(h) }

    assert_empty illegal,
                 "these are required hops out of the credential-rotation SOP to files that are neither " \
                 "registered SOPs nor declared write targets: #{illegal.inspect}. Per AGENTS.md an SOP " \
                 "is executable start to finish from its own file. Inline what the reader needs, move " \
                 "the reference under '#{BACKGROUND_HEADING}', or declare it in WRITE_TARGETS here."

    # At least one hop must be a real composition seam, or "standalone" is being
    # proved on a file that simply links nothing.
    assert_operator hops.count { |h| registered.include?(h) }, :>=, 1,
                    "the SOP composes with no registered SOP at all — credential-filing is its " \
                    "intended seam, and a body with zero registered hops makes this guard vacuous"
  end

  # The exception list is not a free pass: every entry must STILL be a link in the
  # executable body. Delete a write target from the SOP and its allowance rots here
  # instead of quietly widening what the guard permits.
  test "the write-target allowances are not stale" do
    hops = links_in(executable_body)
    stale = WRITE_TARGETS.keys.reject { |t| hops.include?(t) }

    assert_empty stale,
                 "these WRITE_TARGETS allowances name files the SOP no longer links: #{stale.inspect}. " \
                 "Remove them, or this list is permitting hops nobody has reviewed."
  end
end
