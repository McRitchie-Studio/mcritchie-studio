# frozen_string_literal: true

require "test_helper"

# NOBODY HAND-RUNS THE INSTALLER — asserted across every doc an agent EXECUTES, not just
# the registered SOP table.
#
# WHAT WENT WRONG THE FIRST TIME (PR #1301). PR #1291 shipped a preflight message telling
# agents that entry-doc drift is closed by `bin/release ship`'s owned `sync_agent_docs`
# step and that nobody hand-runs the installer, naming exactly two exemptions in
# docs/agents/modules/docs-maintenance.md. Alex's `share-insights` SOP went on prescribing
# `bin/install-agent-docs` anyway, so an agent running it was told to do the exact thing
# the doc it had just been pointed at says nobody does.
#
# WHAT WENT WRONG THE SECOND TIME (docs-still-prescribe-installer, this file's widening).
# The PR #1301 sweep read ONLY the ~29 files in the SOP invocation table, while its name
# ("registered_sop_...") and its floor message implied it covered the docs tree. Four live
# sites kept the prescription because none of them is a registered SOP:
#
#   system/atomic-capture-hook.md   x3  "the orchestrator runs bin/install-agent-docs
#                                        after this change is reviewed and merged"
#   modules/llm-adapters.md         :57 "fix docs/agents/claude.md, run
#                                        bin/agent-runtime install, and re-run the smoke test"
#   maintenance/kickoff-docs-registry.md  "run bin/install-agent-docs after the edits and
#                                        confirm the generated file matches"
#   skills/README.md                :53 "2. Run bin/agent-runtime install to install it locally."
#
# The last two are the ones that matter most, and they are why the corpus below is what it
# is. On 2026-09-08 an agent published unshipped mid-branch text to every session on the
# machine, and the instruction it followed had been copied out of a KICKOFF BRIEF — the
# same shape as maintenance/kickoff-docs-registry.md. And skills/README.md's "Adding a
# skill" procedure told a skill author to install a brand-new, unshipped skill globally.
#
# WHY THIS CORPUS AND NOT "EVERY LIVE AGENT DOC". The predicate below is deliberately
# crude — ANY mention is a hit (see the DO-NOT-CLASSIFY note on INSTALLER). That works
# only where the base rate of innocent mentions is near zero, which is true of docs an
# agent EXECUTES as a procedure and false of docs that merely DESCRIBE the machinery.
# Measured over docs/agents on 2026-09-09: ~20 live installer mentions, of which ~14 are
# correct description — modules/docs-maintenance.md stating the rule, modules/heartbeats.md
# and system/devops-cycle-design.md describing the owned ship step, system/house-burn-down.md
# and system/ecosystem-build.md documenting Phase 5b bringup, agents/alex/role.md's review
# checklist, shared/insights.md's generated header. Widening this any-mention predicate to
# all of docs/agents would need ~12 exemptions covering exactly the files where a future
# directive could hide, which is a guard that looks tree-wide and holds an allowlist of
# whatever exists today.
#
# THE OTHER FAMILY IS SWEPT TREE-WIDE, AND DELIBERATELY SO. test/docs/ship_docs_sync_docs_test.rb
# reads all ~121 live agent docs for "the installer runs from the PRIMARY", because that
# claim IS narrowly phraseable (two regexes, zero false positives). Two families, two
# instruments: a narrow claim gets a tree-wide classifier, a broad claim gets an
# any-mention sweep over the docs where any mention is suspect.
#
# SO THE SCOPE BOUNDARY IS PART OF THE CONTRACT. A doc under system/ or modules/ that
# starts prescribing an install is NOT caught here. That is a chosen limit, not an
# oversight, and the test at the bottom pins the sentence in docs-maintenance.md that
# states it — because the failure this widening was filed against was a guard whose name
# promised more than it held.
class ExecutableDocsInstallerTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs/agents")
  INDEX  = AGENTS.join("index.md")

  # Same shape the SOP registry uses (see sop_registry_docs_test.rb). The name class MUST
  # admit spaces and capitals or the `Alex Heartbeat` rows silently drop out — and a
  # heartbeat is exactly the kind of launcher that would re-acquire an install step.
  ROW = /^\|\s*`([A-Za-z0-9][A-Za-z0-9 -]*)`[^|]*\|\s*([^|]+?)\s*\|\s*`mcritchie-studio\/(\S+?)`\s*\|/

  # ⛔ DO NOT CLASSIFY THE MENTION. The tempting refinement is to count only a FENCED
  # command as "prescribed" and wave prose through. That is the trap this repo has already
  # sprung twice on install-agent-docs guards (sop_registry_install_test.rb): every
  # blacklist gets walked around by the next spelling, and a directive reads just as
  # imperatively in prose ("then run `bin/install-agent-docs`") as in a ```bash block.
  #
  # It was re-tested during this widening and the answer got firmer. A verb-mood detector
  # cannot separate the defect from correct prose: "the orchestrator runs
  # bin/install-agent-docs after this merges" (a directive, atomic-capture-hook.md:269)
  # and "ship auto-runs bin/install-agent-docs from the ship workspace" (correct,
  # heartbeats.md:329) differ only in whether the subject is a person or a pipeline step.
  # So ANY mention in an executed doc is a hit that owes an explicit exemption. A doc that
  # needs to state the rule can do what share-insights.md does — point one hop at
  # docs-maintenance.md — and never name the binary at all.
  INSTALLER = /install-agent-docs|agent-runtime\s+install/

  # Docs an agent EXECUTES, in three groups. Each group carries its own floor below,
  # because a count floor over the union survives losing an entire group.
  KICKOFF_GLOB = "maintenance/kickoff-*.md"
  SKILLS_GLOB  = "skills/**/*.md"

  # The runs docs-maintenance.md § Editing The Entry Docs keeps legitimate, mapped to the
  # executed file that documents each. `bin/agent-runtime install` at fresh-machine bringup
  # (exemption 1) lives in system/house-burn-down.md and system/ecosystem-build.md, which
  # are DESCRIPTIVE docs outside this corpus by construction.
  EXEMPT = {
    "agents/steffon/sops/production-deploy.md" =>
      "documents the ship's OWNED sync_agent_docs step and the by-hand fallback " \
      "`bin/release ship` prints when that step warns — exemption 2 in docs-maintenance.md",
    "skills/README.md" =>
      "the skills tree's own README: its subject IS the publish mechanism, so it names the " \
      "installer to DESCRIBE what publishes this directory and to scope `bin/agent-runtime " \
      "install` to fresh-machine bringup (exemption 1). Its 'Adding a skill' procedure no " \
      "longer prescribes a run — it warns against one."
  }.freeze

  def registered_files
    INDEX.read.lines.filter_map { |line| ROW.match(line)&.[](3) }.uniq
                    .map { |p| p.sub(%r{\Adocs/agents/}, "") }
  end

  def kickoff_files
    Dir.glob(AGENTS.join(KICKOFF_GLOB)).map { |f| Pathname.new(f).relative_path_from(AGENTS).to_s }.sort
  end

  def skill_files
    Dir.glob(AGENTS.join(SKILLS_GLOB)).map { |f| Pathname.new(f).relative_path_from(AGENTS).to_s }.sort
  end

  # Every corpus path that exists and was actually READ. The floors below count THIS, not
  # the row/glob count: a row pointing at a missing file contributes no bytes to scan, and
  # a sweep of zero bytes is the failure mode this whole test exists to refuse.
  def swept(paths)
    paths.uniq.filter_map do |rel|
      full = AGENTS.join(rel)
      [rel, full.read] if full.exist?
    end
  end

  def corpus
    swept(registered_files + kickoff_files + skill_files)
  end

  def prescribes_installer?(body)
    INSTALLER.match?(body)
  end

  test "the registered-SOP group is still swept at full breadth" do
    files = swept(registered_files)

    # THE FLOOR, and the reason it is here: the sweep's whole value is breadth, and a ROW
    # regex that stops matching turns "nothing prescribes an install" into a statement about
    # an empty set. That failure mode has bitten this family of test repeatedly — twice on
    # 2026-09-08 alone. The registry carries 29 registered files today.
    assert_operator files.length, :>=, 20,
                    "swept only #{files.length} registered SOP file(s) — the registry table in " \
                    "docs/agents/index.md has ~29. The ROW regex has stopped matching (it must admit " \
                    "SPACES and CAPITALS for the `Alex Heartbeat` rows), so this group is now asserting " \
                    "NOTHING. Fix the scan; do not lower this floor."

    # A COUNT FLOOR ALONE IS HALF THE GUARD, and the number above is why. Measured
    # 2026-09-08: narrowing the name class to /[a-z0-9-]+/ — the exact break the message
    # above names — drops the five `<Soul> Heartbeat` rows and leaves 24, which clears a
    # floor of 20 while the sweep has gone BLIND to the launchers. A real
    # `bin/install-agent-docs` added to alex/HEARTBEAT.md then passes. So pin the class this
    # file calls highest-risk by NAME, not by count.
    heartbeats = files.map(&:first).grep(%r{/HEARTBEAT\.md\z})
    assert_operator heartbeats.length, :>=, 5,
                    "the sweep matched only #{heartbeats.length} HEARTBEAT.md row(s) — the registry has " \
                    "one per soul (carl, avi, turf_monster, steffon, alex). The ROW name class has stopped " \
                    "admitting SPACES and CAPITALS, so the `<Soul> Heartbeat` rows dropped out while the " \
                    "count floor above still passed. A heartbeat is exactly the launcher that would " \
                    "re-acquire an install step. Fix the scan; do not lower this."
  end

  # THE GROUPS THIS WIDENING ADDED, floored SEPARATELY. A union floor of ~30 is cleared by
  # the registered SOPs alone, so it would stay green with both new globs matching nothing —
  # which is precisely the "asserting an empty set" failure the registered floor exists to
  # refuse. Each group therefore proves its own breadth, and each is pinned BY NAME to the
  # file that carried the defect, because a glob can keep matching while losing the one doc
  # the group was written for.
  test "the kickoff-brief group is swept and pins the brief that carried the defect" do
    files = swept(kickoff_files)

    assert_operator files.length, :>=, 3,
                    "swept only #{files.length} kickoff brief(s) — docs/agents/maintenance carries three " \
                    "(kickoff-docs-registry, kickoff-log-rotation, kickoff-standard-emails). The " \
                    "KICKOFF_GLOB has stopped matching, so this group asserts NOTHING."

    assert_includes files.map(&:first), "maintenance/kickoff-docs-registry.md",
                    "kickoff-docs-registry.md dropped out of the sweep — it is the brief this group was " \
                    "written for (it told its agent to run bin/install-agent-docs after the edits), so " \
                    "its absence is the failure mode, not a passing run"
  end

  test "the installed-skills group is swept and pins the tree's own README" do
    files = swept(skill_files)

    assert_operator files.length, :>=, 2,
                    "swept only #{files.length} file(s) under docs/agents/skills — the tree carries at " \
                    "least README.md and wrap/SKILL.md. The SKILLS_GLOB has stopped matching, so this " \
                    "group asserts NOTHING. These files install GLOBALLY to ~/.claude/skills and " \
                    "~/.codex/skills, so an install directive here reaches every session on the machine."

    assert_includes files.map(&:first), "skills/README.md",
                    "skills/README.md dropped out of the sweep — its 'Adding a skill' procedure is the " \
                    "site this group was written for"
    assert_operator files.map(&:first).grep(%r{\Askills/.+/SKILL\.md\z}).length, :>=, 1,
                    "the sweep matched no skills/<name>/SKILL.md — a SKILL.md is the file that actually " \
                    "ships to every session, so losing that shape while README.md still matches is the " \
                    "partial break this assertion exists to catch"
  end

  test "no executed doc prescribes a hand-run of the docs installer outside the exemption list" do
    offenders = corpus.select { |path, body| prescribes_installer?(body) && !EXEMPT.key?(path) }

    assert_empty offenders.map(&:first),
                 "These docs are EXECUTED by an agent (a registered SOP, a kickoff brief, or a globally " \
                 "installed skill) and they prescribe a docs-installer run, which the exemption list in " \
                 "docs/agents/modules/docs-maintenance.md § Editing The Entry Docs does not name. " \
                 "Nobody hand-runs the installer: the entry docs, the user-global skills, the Claude/Codex " \
                 "hooks and the ~/.zprofile Ruby PATH block are all published by the owned `sync_agent_docs` " \
                 "step of `bin/release ship`. A hand-run does not CLOSE drift, it MOVES it — every other " \
                 "session's preflight goes red, and from a worktree it publishes unshipped mid-branch text " \
                 "to every session on this machine. Either drop the step, or (if it installs something the " \
                 "ship workspace cannot) add it to docs-maintenance.md AND to EXEMPT here, with the reason."
  end

  # NO DEAD EXEMPTIONS. An exemption for a file that no longer mentions the installer is
  # coverage you do not have: it reads as "this site is known and allowed" while holding
  # nothing, and it would silently absolve a REAL install step added to that file later.
  # (Same lesson as the `phantom` guard in sop_registry_install_test.rb.)
  test "every exempted file is still in the corpus and still mentions the installer" do
    files = corpus.to_h

    EXEMPT.each_key do |path|
      assert_includes files.keys, path,
                      "#{path} is exempted here but is no longer swept — it left the SOP registry, the " \
                      "kickoff glob, or the skills tree. The exemption is dead. Remove it."
      assert prescribes_installer?(files.fetch(path)),
             "#{path} is exempted here but no longer mentions the installer at all. Drop the exemption, " \
             "or the next real install step added to this file walks straight through."
    end
  end

  # THE REGRESSION THE FIRST PASS FIXED. share-insights.md must not name the installer in
  # any form. It states the rule by pointing one hop at docs-maintenance.md instead — which
  # is both the SOP standard (one hop to a registered primitive) and what keeps it out of
  # the exemption list above.
  test "share-insights prescribes no install step and says why" do
    body = AGENTS.join("agents/alex/sops/share-insights.md").read

    refute prescribes_installer?(body),
           "the share-insights SOP names the docs installer again. Its output is the tracked doc " \
           "docs/agents/shared/insights.md, which the installer has NEVER published, and a session reads " \
           "insights from the board via bin/session-insights. An install step here distributes nothing " \
           "this SOP produces."

    assert_match(/installs nothing, and owes no install step/, body,
                 "the share-insights SOP lost the note explaining why it has no install step — without it " \
                 "the step reads as an oversight and gets helpfully added back")
    assert_match(%r{bin/rails insights:doc}, body,
                 "the share-insights SOP no longer runs the doc generator — its one real command")
  end

  # THE REGRESSIONS THIS WIDENING FIXED, pinned individually. The sweep above would catch a
  # verbatim revert, but these say WHICH sentence was wrong and what replaced it, so a
  # future editor restoring "the orchestrator runs the installer" reads the reason here
  # instead of rediscovering it. Each asserts the corrected doc still carries the rule it
  # was given, not merely that the binary is absent — an unexplained deletion is how the
  # instruction gets helpfully added back.
  test "the hook-wiring doc defers to the owned ship step instead of naming a runner" do
    body = AGENTS.join("system/atomic-capture-hook.md").read
    # All three sites sit inside BLOCKQUOTES and wrap across lines, so the rule reads
    # "**Nobody\n> hand-runs ...". Strip the `>` markers before collapsing whitespace or
    # every assertion below silently matches nothing — which would leave this test green
    # while holding none of its claims.
    flat = body.gsub(/^[ \t]*>[ \t]?/, "").gsub(/\s+/, " ")

    refute_match(/orchestrator runs/i, flat,
                 "system/atomic-capture-hook.md again names 'the orchestrator' as the party who runs the " \
                 "installer after this merges. There is no such party: the wiring lands via the owned " \
                 "sync_agent_docs step of `bin/release ship`.")
    assert_equal 3, flat.scan(/[Nn]obody hand-runs th(?:at|e) installer/).length,
                 "system/atomic-capture-hook.md carried THREE install directives (the PostToolUse block, " \
                 "the SessionEnd block, and the SessionStart activation note) and each was replaced with " \
                 "the no-hand-run rule. A count other than 3 means one was reverted or one rule line was " \
                 "dropped, leaving that block's reader with no guidance again."

    # The installer DOES wire these hooks — that description is correct and must survive.
    # Deleting it would be the opposite error: a reader who does not know the hooks are
    # published by the installer hand-edits ~/.claude/settings.json instead, which is the
    # very thing the surrounding blockquotes forbid.
    assert_match(/install-agent-docs. wires this hook idempotently/, flat,
                 "the doc lost its DESCRIPTION of what the installer wires. The fix here was to remove the " \
                 "directive, not the mechanism: without it the reader hand-edits the global settings file.")
  end

  test "the llm-adapter smoke-test loop no longer routes through a hand install" do
    body = AGENTS.join("modules/llm-adapters.md").read.gsub(/\s+/, " ")

    refute_match(%r{run .bin/agent-runtime install}i, body,
                 "modules/llm-adapters.md:57 again tells a failing smoke test to run the installer. The " \
                 "generated root CLAUDE.md is republished by the ship's owned sync_agent_docs step; the " \
                 "smoke test is re-run against a session started after that ship.")
    assert_match(/do not hand-run the installer/i, body,
                 "modules/llm-adapters.md lost the sentence explaining why the smoke-test loop does not " \
                 "install by hand — without it the shortcut reads as an omission and comes back")
  end

  test "the docs-registry kickoff brief tells its agent not to publish" do
    body = AGENTS.join("maintenance/kickoff-docs-registry.md").read.gsub(/\s+/, " ")

    refute prescribes_installer?(AGENTS.join("maintenance/kickoff-docs-registry.md").read),
           "maintenance/kickoff-docs-registry.md names the installer again. A KICKOFF BRIEF is the exact " \
           "shape that caused the 2026-09-08 global publish: an agent copied the instruction out of a " \
           "brief and pushed unshipped mid-branch text to every session on the machine."
    assert_match(/not part of this task/i, body,
                 "the brief lost the sentence putting the publish OUTSIDE the task's scope — that framing " \
                 "is what stops the executing agent from treating drift as work it owes")
  end

  test "the skills README warns against a hand install instead of prescribing one" do
    body = AGENTS.join("skills/README.md").read.gsub(/\s+/, " ")

    refute_match(/\d\.\s*Run .bin/i, body,
                 "skills/README.md's 'Adding a skill' procedure again has a numbered step telling the " \
                 "author to run the installer. A brand-new skill installed by hand from a worktree goes " \
                 "GLOBAL — to ~/.claude/skills and ~/.codex/skills — along with that branch's AGENTS.md.")
    assert_match(/Do not install it by hand/i, body,
                 "skills/README.md lost the warning that replaced the install step")
    assert_match(/FRESH-MACHINE BRINGUP ONLY/, body,
                 "skills/README.md's operator fence no longer scopes `bin/agent-runtime install` to " \
                 "bringup — unscoped, it reads as a routine command and is exemption 1 being misread")
  end

  # THE POLICY THE EXEMPTION LIST ENCODES. EXEMPT above is only meaningful while
  # docs-maintenance.md still carries the rule and still closes the list. If that prose is
  # deleted or reworded past recognition, this test's exemptions become an unmoored local
  # opinion, so go RED here rather than keep enforcing a rule the docs no longer state.
  test "docs-maintenance still states the no-hand-run rule and closes the exemption list" do
    body = AGENTS.join("modules/docs-maintenance.md").read

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

  # THE SCOPE BOUNDARY IS THE POINT OF THIS FILE'S EXISTENCE. The defect that produced this
  # widening was not a missing assertion, it was a guard NAMED for more coverage than it
  # held: a reader saw "registered_sop_installer_docs_test" sweeping the SOP table and
  # reasonably assumed the docs tree was covered. Renaming the file fixes the name; this
  # test fixes the DOCUMENTED claim, so the limit survives someone reading only the module.
  test "docs-maintenance names this guard and states what it does NOT cover" do
    body = AGENTS.join("modules/docs-maintenance.md").read.gsub(/\s+/, " ")

    assert_match(%r{test/docs/executable_docs_installer_test\.rb}, body,
                 "docs-maintenance.md no longer names this guard, or still names it by its pre-widening " \
                 "filename (registered_sop_installer_docs_test.rb). The stale name is the defect this " \
                 "widening was filed against: it advertises coverage of the SOP table only.")
    assert_match(/does not sweep|not swept|outside this sweep/i, body,
                 "docs-maintenance.md names this guard without stating its LIMIT. An any-mention sweep " \
                 "runs over executed docs (registered SOPs, kickoff briefs, installed skills) and " \
                 "deliberately NOT over descriptive docs under system/ and modules/. Say so, or the next " \
                 "reader over-trusts it exactly as the last one did.")
  end

  # MUTATION PROOF: the detector is not inert. Run the SAME predicate the sweep uses over
  # bodies shaped like the defect — the fenced command share-insights.md carried, a prose
  # directive, and the two spellings this widening removed — and over one that only points
  # at the module. A guard that cannot fail on a reintroduced defect is decoration, and this
  # file's whole claim rests on this predicate.
  test "the installer detector fires on a reintroduced install step" do
    fenced   = "## Procedure\n\nDistribute the docs:\n\n```bash\nbin/install-agent-docs\n```\n"
    prose    = "When the doc changes, then run `bin/install-agent-docs` from the primary.\n"
    runtime  = "Bring the machine up with `bin/agent-runtime install` first.\n"
    orch     = "The orchestrator runs `bin/install-agent-docs` after this change is merged.\n"
    skillstep = "2. Run `bin/agent-runtime install` to install it locally.\n"
    clean    = "See [`docs-maintenance.md`](../../../modules/docs-maintenance.md) " \
               "§ Editing The Entry Docs. This SOP installs nothing.\n"

    assert prescribes_installer?(fenced), "the detector missed a FENCED install command — the exact shape " \
                                          "share-insights.md carried at :39"
    assert prescribes_installer?(prose), "the detector missed a PROSE install directive — the shape a " \
                                         "fence-only scan would wave through"
    assert prescribes_installer?(runtime), "the detector missed `bin/agent-runtime install`, the other " \
                                           "spelling of the same publish"
    assert prescribes_installer?(orch), "the detector missed the third-person directive shape " \
                                        "atomic-capture-hook.md carried — the one a verb-mood classifier " \
                                        "cannot tell from 'ship auto-runs the installer'"
    assert prescribes_installer?(skillstep), "the detector missed the numbered install step " \
                                             "skills/README.md carried at :53"
    refute prescribes_installer?(clean), "the detector fires on a doc that merely POINTS at " \
                                         "docs-maintenance.md — it would force an exemption for stating " \
                                         "the rule correctly, and every executed doc would end up exempt"
  end
end
