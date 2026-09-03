# frozen_string_literal: true

require "test_helper"

# The SOP registry is a DECLARATION, and until this test existed nothing checked
# it against the disk. An SOP is invoked by NAME — Mr. McRitchie says `clean-up`
# and the agent is expected to resolve that phrase through the registry table in
# docs/agents/index.md to a file. Three separate surfaces have to agree:
#
#   1. docs/agents/index.md      — TWO registry tables (top-level + reference),
#                                  generated verbatim into $PROJECTS_ROOT/AGENTS.md
#   2. docs/agents/claude.md     — the Claude adapter's prose list of invocations,
#                                  generated into $PROJECTS_ROOT/CLAUDE.md
#   3. docs/agents/agents/<soul>/sops/<sop>.md — the file that actually runs
#
# Add an SOP and forget one table and the failure is SILENT: the agent reads a
# registry that does not name the SOP, treats the invocation as ordinary prose,
# and improvises — which is precisely the drift the SOP Invocation Standard exists
# to kill. The registry claiming an SOP that is not on disk fails the other way:
# the agent is sent to read a file that is not there.
#
# So we assert the POSITIVE INVARIANT — registry and disk are the SAME SET, and
# every registered path resolves — rather than blacklisting the ways they drift.
class SopRegistryDocsTest < ActiveSupport::TestCase
  DOCS_ROOT   = Rails.root.join("docs/agents")
  INDEX       = DOCS_ROOT.join("index.md")
  CLAUDE      = DOCS_ROOT.join("claude.md")
  SOPS_GLOB   = DOCS_ROOT.join("agents/*/sops/*.md")

  # Rows look like:  | `clean-up` | Alex | `mcritchie-studio/docs/agents/agents/alex/sops/clean-up.md` |
  # The invocation may carry a trailing note — `pr-review-primary` (role SOP),
  # `qa-deploy` (legacy alias) — so capture the backticked name, not the whole cell.
  #
  # The name charset MUST admit spaces and capitals. The HEARTBEAT rows are spelled
  # `Avi Heartbeat` / `Steffon Heartbeat` / `Alex Heartbeat`, so a `[a-z0-9-]+` class
  # silently declines to match them — which left every HEARTBEAT.md path completely
  # UNPINNED, in the one class of doc a soul launches from. A regex that quietly
  # matches nothing is the same failure as a gate that quietly passes everything.
  ROW = /^\|\s*`([A-Za-z0-9][A-Za-z0-9 -]*)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

  def registry_rows
    INDEX.read.lines.filter_map do |line|
      m = ROW.match(line)
      next unless m

      { invocation: m[1], owner: m[2].strip, path: m[3] }
    end
  end

  def sop_files_on_disk
    Dir.glob(SOPS_GLOB).map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }.sort
  end

  test "every registered SOP path exists on disk" do
    missing = registry_rows.reject { |row| Rails.root.join(row[:path]).exist? }

    assert_empty missing.map { |r| "#{r[:invocation]} -> #{r[:path]}" },
                 "The SOP registry in docs/agents/index.md names files that do not exist. An agent told to " \
                 "run one of these would be sent to read a missing file."
  end

  test "every SOP file on disk is registered by name in docs/agents/index.md" do
    registered = registry_rows.map { |r| r[:path] }.to_set
    unregistered = sop_files_on_disk.reject { |path| registered.include?(path) }

    assert_empty unregistered,
                 "These SOP files exist but no registry row in docs/agents/index.md names them. An agent " \
                 "cannot resolve an SOP it cannot find in the registry — it will treat the invocation as " \
                 "ordinary prose and improvise. Add a row to BOTH registry tables."
  end

  # The two tables are the SAME registry printed twice (the second exists for agents
  # that jump straight to the reference section). A name in one and not the other is
  # a coin-flip on which an agent reads.
  test "the two registry tables in index.md name the same set of SOP files" do
    text = INDEX.read
    reference_heading = text.index("## SOP Registry")

    refute_nil reference_heading, "docs/agents/index.md lost its '## SOP Registry' reference section"

    top_paths = text[0...reference_heading].lines.filter_map { |l| ROW.match(l)&.[](3) }
    ref_paths = text[reference_heading..].lines.filter_map { |l| ROW.match(l)&.[](3) }

    # BOTH tables carry the heartbeat rows AND the SOP rows — an earlier version of
    # this comment claimed heartbeats lived only in the top table, and its regex could
    # not match them anyway, so the claim was never tested. Compare the FULL path sets.
    assert_equal top_paths.to_set, ref_paths.to_set,
                 "The two SOP registry tables in docs/agents/index.md disagree. Both must list every SOP " \
                 "and every heartbeat — an agent may read either one."
  end

  # The one class of doc a soul LAUNCHES from. Pinned explicitly, because they are the
  # rows the old `[a-z0-9-]+` name class silently declined to match (`Avi Heartbeat` —
  # space, capitals), leaving every HEARTBEAT.md path completely unverified.
  test "every heartbeat launcher in the registry exists on disk" do
    heartbeats = registry_rows.select { |r| r[:path].end_with?("HEARTBEAT.md") }

    assert_operator heartbeats.length, :>=, 3,
                    "expected the Avi/Steffon/Alex heartbeat rows in the registry; the ROW regex may have " \
                    "stopped matching them again (they carry a SPACE and CAPITALS)"

    heartbeats.each do |row|
      assert_path_exists Rails.root.join(row[:path]),
                         "registry names heartbeat #{row[:invocation]} -> #{row[:path]}, which does not exist"
    end
  end

  # The Claude adapter names invocations in prose ("such as `pr-review`, …"). It is
  # the file Claude Code AUTO-LOADS, so an SOP it never names is one Claude is least
  # likely to resolve. Assert the adapter's prose list is a subset of the registry —
  # it may abbreviate, but it may never invent.
  test "every invocation the Claude adapter names is a real registered invocation" do
    invocations = registry_rows.map { |r| r[:invocation] }.to_set
    body = CLAUDE.read

    # The scan is SCOPED to the SOP-invocation sentence on purpose. A whole-file scan
    # for backticked hyphenated tokens over-reaches: the adapter legitimately names the
    # feature SHAPES (`ui-only`, `onchain-vertical`) and other hyphenated terms that are
    # not SOPs, so it would fail on correct docs — a guard that cries wolf gets deleted.
    #
    # But the FIRST cut of this test scoped it and stopped there, which fails OPEN: a
    # bogus SOP name injected AFTER the anchor kept the test GREEN, and any reword that
    # moved the list — or renamed the anchor — turned the whole assertion into a silent
    # NO-OP with nothing to tell you. So the anchor itself is now ASSERTED, and so is a
    # non-empty result. A check that can be switched off by editing prose is not a check.
    anchor = body.index("resolve that phrase")
    refute_nil anchor,
               "docs/agents/claude.md no longer contains the 'resolve that phrase' SOP-invocation anchor. " \
               "This test scopes its scan to that sentence — without the anchor it would silently check " \
               "NOTHING. Restore the anchor, or rewrite this test to scan whatever replaced it."

    named = body[0..anchor].scan(/`([a-z0-9][a-z0-9-]*-[a-z0-9-]*)`/).flatten.uniq

    # A subset assertion over an EMPTY set passes trivially — the exact way this family
    # of test fails open. Prove the scan is looking at something before trusting it.
    assert_operator named.length, :>=, 3,
                    "the Claude adapter's SOP sentence names no invocations at all — either it was " \
                    "reworded past recognition, or this scan has quietly stopped seeing them"

    unknown = named.reject { |n| invocations.include?(n) }

    assert_empty unknown,
                 "docs/agents/claude.md names SOP invocations that are not in the registry: #{unknown.inspect}. " \
                 "Claude auto-loads this file — it must not point at an SOP that cannot be resolved."
  end

  # The reason this test exists at all.
  test "clean-up resolves end to end" do
    row = registry_rows.find { |r| r[:invocation] == "clean-up" }

    refute_nil row, "`clean-up` is not in the SOP registry"
    assert_equal "Alex", row[:owner]
    assert_path_exists Rails.root.join(row[:path])

    body = Rails.root.join(row[:path]).read
    assert_match(/zero open tasks/i, body, "the clean-up SOP must state its goal: zero open tasks")
    assert_match(/Phase 0 — Scope guard/, body, "the clean-up SOP must carry the carve-out phase")
  end

  # THE TWO BACKLOG SOPs. These are the prioritization procedure — the thing that used
  # to be re-explained by hand every session — so what makes them worth invoking is not
  # that the files EXIST (the tests above already prove that) but that they still carry
  # the specific rules a reader acts on. Every pattern below is a rule a REVIEW had to
  # put there, and each one is a rule whose loss would be SILENT: the SOP would still
  # read fluently, still resolve from the registry, and still hand a session a confident
  # procedure — with the guard rail gone.
  #
  #   * the wave-subtraction rule was added after a reader could have run 4 builders
  #     PLUS a 5-agent review wave against a 5-agent cap that exists because a fan-out
  #     once exhausted the board's Postgres connections and 500'd it;
  #   * the two agent_context rules were added after the fold recipe was found to
  #     DESTROY the survivor's context — first by overwriting it, then (after that fix)
  #     by prescribing a hand-transcription whose read-back checked presence, not
  #     equality — inside the one step whose whole purpose is losing neither half.
  BACKLOG_SOP_RULES = {
    "process-backlog" => [
      [/10 or more/,                        "the mandatory review pivot at ten submitted tasks"],
      [/NAME the evidence/,                 "that an archive requires named evidence"],
      [/Tier A/,                            "the own-tasks-first ranking tier"],
      [/5 − \(builders still in flight\)/,  "the review-wave subtraction rule"],
      [/REPLACES; it does not append/,      "that --agent-context overwrites the survivor's context"],
      [/bin\/task field/,                   "reading agent_context raw instead of retyping a rendered report"],
      [/presence is not equality/,          "that the fold read-back must COMPARE, not merely find the old text"]
    ],
    "work-backlog" => [
      [/mascot_session/,                    "the own-session task filter"],
      # NOT /two or three/: that phrase is the file's H1 title and its Step 3 heading,
      # so it holds green even with the ceiling rule deleted outright. Pin the rule.
      [/three is the ceiling/,              "its two-to-three parallel ceiling"],
      [/5 − \(builders still in flight\)/,  "the review-wave subtraction rule"]
    ]
  }.freeze

  test "the backlog SOPs resolve end to end and carry their load-bearing rules" do
    BACKLOG_SOP_RULES.each do |invocation, rules|
      row = registry_rows.find { |r| r[:invocation] == invocation }

      refute_nil row, "`#{invocation}` is not in the SOP registry"
      assert_equal "Shared", row[:owner]
      assert_path_exists Rails.root.join(row[:path])

      body = Rails.root.join(row[:path]).read
      rules.each do |pattern, what|
        assert_match pattern, body, "the #{invocation} SOP must state #{what}"
      end
    end
  end

  # The minus in the subtraction rule is U+2212, not ASCII "-". A pattern that silently
  # stopped matching would leave the rule unpinned while the suite stayed green — the
  # exact failure mode every guard in this file exists to refuse — so assert the
  # character itself rather than trusting the literal above to keep its bytes.
  test "the subtraction rule pattern uses the same minus sign the SOPs do" do
    pattern = BACKLOG_SOP_RULES["process-backlog"].find { |_, what| what.include?("subtraction") }.first

    assert_includes pattern.source, "\u2212",
                    "the subtraction-rule pattern must carry U+2212 MINUS SIGN; an ASCII hyphen matches nothing"
  end
end
