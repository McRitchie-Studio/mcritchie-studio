# frozen_string_literal: true

require "test_helper"

# NOBODY HAND-RUNS THE INSTALLER — asserted across every registered SOP, not just
# the one that broke.
#
# WHAT WENT WRONG. PR #1291 shipped a preflight message telling agents that entry-doc
# drift is closed by `bin/release ship`'s owned `sync_agent_docs` step and that nobody
# hand-runs the installer, naming exactly two exemptions in
# docs/agents/modules/docs-maintenance.md. Alex's `share-insights` SOP — a first-class
# entry in the invocation table — went on prescribing `bin/install-agent-docs` anyway.
# So an agent running share-insights was told to do the exact thing the doc it had just
# been pointed at says nobody does, and bin/release.rb already called that run history
# ("previously the only owned run was Alex's share-insights act").
#
# THE STEP WAS DEAD, NOT MERELY SUPERSEDED — which is why the SOP dropped it rather than
# joining the exemption list. `bin/rails insights:doc` writes docs/agents/shared/insights.md.
# The installer's payload is docs/agents/index.md -> AGENTS.md, docs/agents/claude.md ->
# CLAUDE.md, and docs/agents/skills/** -> the two runtime skill dirs (bin/install-agent-docs
# PAIRS + SKILL_PAIRS). insights.md is in NEITHER set, and the feed-forward path a session
# actually reads is the board (bin/session-insights GETs /api/v1/insights). The step
# distributed nothing the SOP produced, while publishing whatever tree its runner stood in
# to every session on the machine.
#
# WHY A SWEEP AND NOT A GREP FOR THE SENTENCE. Pinning share-insights alone would catch the
# site we already fixed and nothing else. The property worth holding is about the WHOLE
# registry: an agent resolves an SOP by name through the invocation table, so ANY registered
# file that prescribes an install can re-open this contradiction. The sweep catches a fourth
# site — one that does not exist yet — which a regression pin never could.
class RegisteredSopInstallerDocsTest < ActiveSupport::TestCase
  INDEX = Rails.root.join("docs/agents/index.md")

  # Same shape the SOP registry uses (see sop_registry_docs_test.rb). The name class MUST
  # admit spaces and capitals or the `Alex Heartbeat` rows silently drop out — and a
  # heartbeat is exactly the kind of launcher that would re-acquire an install step.
  ROW = /^\|\s*`([A-Za-z0-9][A-Za-z0-9 -]*)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

  # ⛔ DO NOT CLASSIFY THE MENTION. The tempting refinement is to count only a FENCED
  # command as "prescribed" and wave prose through. That is the trap this repo has already
  # sprung twice on install-agent-docs guards (sop_registry_install_test.rb): every
  # blacklist gets walked around by the next spelling, and a directive reads just as
  # imperatively in prose ("then run `bin/install-agent-docs`") as in a ```bash block.
  # So ANY mention in a registered file is a hit that owes an explicit exemption. A doc
  # that needs to state the rule can do what share-insights.md does — point one hop at
  # docs-maintenance.md — and never name the binary at all.
  INSTALLER = /install-agent-docs|agent-runtime\s+install/

  # The two runs docs-maintenance.md § Editing The Entry Docs keeps legitimate, mapped to
  # the registered file that documents each. `bin/agent-runtime install` at fresh-machine
  # bringup lives in system/house-burn-down.md, which is NOT in the invocation table, so it
  # is out of this sweep's reach by construction — the exemption below is the other one.
  EXEMPT = {
    "docs/agents/agents/steffon/sops/production-deploy.md" =>
      "documents the ship's OWNED sync_agent_docs step and the by-hand fallback " \
      "`bin/release ship` prints when that step warns — exemption 2 in docs-maintenance.md"
  }.freeze

  def registered_files
    INDEX.read.lines.filter_map { |line| ROW.match(line)&.[](3) }.uniq
  end

  # Every registered path that exists and was actually READ. The floor below counts THIS,
  # not the row count: a row pointing at a missing file contributes no bytes to scan, and a
  # sweep of zero bytes is the failure mode this whole test exists to refuse.
  def swept
    registered_files.filter_map do |path|
      full = Rails.root.join(path)
      [path, full.read] if full.exist?
    end
  end

  def prescribes_installer?(body)
    INSTALLER.match?(body)
  end

  test "no registered SOP prescribes a hand-run of the docs installer outside the exemption list" do
    files = swept

    # THE FLOOR, and the reason it is here: the sweep's whole value is breadth, and a ROW
    # regex that stops matching turns "nothing prescribes an install" into a statement about
    # an empty set. That failure mode has bitten this family of test repeatedly — twice on
    # 2026-09-08 alone. The registry carries 29 registered files today.
    assert_operator files.length, :>=, 20,
                    "swept only #{files.length} registered SOP file(s) — the registry table in " \
                    "docs/agents/index.md has ~29. The ROW regex has stopped matching (it must admit " \
                    "SPACES and CAPITALS for the `Alex Heartbeat` rows), so this test is now asserting " \
                    "NOTHING. Fix the scan; do not lower this floor."

    offenders = files.select { |path, body| prescribes_installer?(body) && !EXEMPT.key?(path) }

    assert_empty offenders.map(&:first),
                 "These registered SOPs prescribe a docs-installer run, and the exemption list in " \
                 "docs/agents/modules/docs-maintenance.md § Editing The Entry Docs does not name them. " \
                 "Nobody hand-runs the installer: the entry docs and user-global skills are published by " \
                 "the owned `sync_agent_docs` step of `bin/release ship`. A hand-run does not CLOSE " \
                 "drift, it MOVES it — every other session's preflight goes red. Either drop the step, " \
                 "or (if it installs something the ship workspace cannot) add it to docs-maintenance.md " \
                 "AND to EXEMPT here, with the reason."
  end

  # NO DEAD EXEMPTIONS. An exemption for a file that no longer mentions the installer is
  # coverage you do not have: it reads as "this site is known and allowed" while holding
  # nothing, and it would silently absolve a REAL install step added to that file later.
  # (Same lesson as the `phantom` guard in sop_registry_install_test.rb.)
  test "every exempted file still mentions the installer and is still registered" do
    files = swept.to_h

    EXEMPT.each_key do |path|
      assert_includes files.keys, path,
                      "#{path} is exempted here but is no longer a registered SOP in docs/agents/index.md " \
                      "— the exemption is dead. Remove it."
      assert prescribes_installer?(files.fetch(path)),
             "#{path} is exempted here but no longer mentions the installer at all. Drop the exemption, " \
             "or the next real install step added to this file walks straight through."
    end
  end

  # THE REGRESSION THIS TASK FIXED. share-insights.md must not name the installer in any
  # form. It states the rule by pointing one hop at docs-maintenance.md instead — which is
  # both the SOP standard (one hop to a registered primitive) and what keeps it out of the
  # exemption list above.
  test "share-insights prescribes no install step and says why" do
    body = Rails.root.join("docs/agents/agents/alex/sops/share-insights.md").read

    refute prescribes_installer?(body),
           "the share-insights SOP names the docs installer again. Its output is the tracked doc " \
           "docs/agents/shared/insights.md, which the installer has NEVER published (its payload is the " \
           "two entry docs plus docs/agents/skills/), and a session reads insights from the board via " \
           "bin/session-insights. An install step here distributes nothing this SOP produces."

    assert_match(/installs nothing, and owes no install step/, body,
                 "the share-insights SOP lost the note explaining why it has no install step — without it " \
                 "the step reads as an oversight and gets helpfully added back")
    assert_match(%r{bin/rails insights:doc}, body,
                 "the share-insights SOP no longer runs the doc generator — its one real command")
  end

  # THE POLICY THE EXEMPTION LIST ENCODES. EXEMPT above is only meaningful while
  # docs-maintenance.md still carries the rule and still closes the list. If that prose is
  # deleted or reworded past recognition, this test's exemptions become an unmoored local
  # opinion, so go RED here rather than keep enforcing a rule the docs no longer state.
  test "docs-maintenance still states the no-hand-run rule and closes the exemption list" do
    body = Rails.root.join("docs/agents/modules/docs-maintenance.md").read

    assert_match(/\*\*Nobody hand-runs the installer\.\*\*/, body,
                 "docs/agents/modules/docs-maintenance.md lost the 'Nobody hand-runs the installer' rule " \
                 "that this sweep enforces")
    assert_match(/Two runs stay legitimate/, body,
                 "docs-maintenance.md lost the two-legitimate-runs exemption list")
    assert_match(/the list is closed/, body,
                 "docs-maintenance.md no longer states that the exemption list is CLOSED — that sentence " \
                 "is what settles share-insights as not-a-third-exemption, and without it the question " \
                 "gets re-litigated by the next agent who finds an installer mention")
  end

  # MUTATION PROOF: the detector is not inert. Run the SAME predicate the sweep uses over
  # bodies shaped like the defect — the exact fenced command share-insights.md carried at
  # :39, and a prose directive — and over one that only points at the module. A guard that
  # cannot fail on a reintroduced defect is decoration, and this file's whole claim rests
  # on this predicate.
  test "the installer detector fires on a reintroduced install step" do
    fenced = "## Procedure\n\nDistribute the docs:\n\n```bash\nbin/install-agent-docs\n```\n"
    prose  = "When the doc changes, then run `bin/install-agent-docs` from the primary.\n"
    runtime = "Bring the machine up with `bin/agent-runtime install` first.\n"
    clean  = "See [`docs-maintenance.md`](../../../modules/docs-maintenance.md) " \
             "§ Editing The Entry Docs. This SOP installs nothing.\n"

    assert prescribes_installer?(fenced), "the detector missed a FENCED install command — the exact shape " \
                                          "share-insights.md carried at :39"
    assert prescribes_installer?(prose), "the detector missed a PROSE install directive — the shape a " \
                                         "fence-only scan would wave through"
    assert prescribes_installer?(runtime), "the detector missed `bin/agent-runtime install`, the other " \
                                           "spelling of the same publish"
    refute prescribes_installer?(clean), "the detector fires on a doc that merely POINTS at " \
                                         "docs-maintenance.md — it would force an exemption for stating " \
                                         "the rule correctly, and every SOP would end up exempt"
  end
end
