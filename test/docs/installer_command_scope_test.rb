# frozen_string_literal: true

require "test_helper"

# WHERE THE DOCS PRINT THE INSTALL COMMAND, THEY MUST PRINT ITS SCOPE.
#
# THE GAP THIS FILE WAS WRITTEN FOR (bootstrap-prescribes-hand-install). Two guards already
# cover the installer, and a live directive sat between them for three PRs:
#
#   test/docs/executable_docs_installer_test.rb  — ANY mention, but only in docs an agent
#                                                  EXECUTES. system/ and modules/ are
#                                                  deliberately outside it: they name the
#                                                  installer legitimately and constantly, so
#                                                  an any-mention rule drowns there.
#   test/docs/ship_docs_sync_docs_test.rb        — tree-wide, but one narrow claim: "the
#                                                  installer's source tree is the PRIMARY".
#                                                  Its three regexes all require the word
#                                                  hub/primary.
#
# So a directive that names NO TREE, in system/ or modules/, scores zero on both. That is
# not a hypothetical: docs/agents/system/bootstrap.md carried a fenced `bin/agent-runtime
# install` followed by "run it by hand here when you only brought up the one app", reachable
# because system/house-burn-down.md's cross-reference appendix routes readers to it by name.
# A reviewer PROVED the gap by mutation on 2026-09-09 — an install directive added to
# modules/worktrees.md naming no tree left BOTH guards green, while the same directive
# phrased "from the hub primary" reddened the second. Net exposure is unchanged by this
# file's task (the site predates both PRs); what changes is that the SPELLING is now covered.
#
# THE PREDICATE, AND WHY IT IS NOT THE REFINEMENT THE OTHER GUARD REJECTS.
# executable_docs_installer_test.rb carries a ⛔ DO NOT CLASSIFY THE MENTION note: counting
# only a FENCED command and waving prose through is a trap that has been sprung twice. That
# warning is about NARROWING an any-mention sweep in a corpus where any mention is already
# suspect — there, fencing loses coverage that exists. Here it is the opposite direction: in
# system/ and modules/ there is NO coverage to lose, an any-mention sweep is impossible
# (measured below), and a fenced command line is the one shape that can be added without
# either existing guard noticing. This widens; it does not narrow.
#
# WHY AN ANY-MENTION SWEEP CANNOT BE USED HERE, measured 2026-09-09 over the 123 live docs.
# Of ~20 installer mentions outside archive/audits, ~14 are correct description that carries
# no bringup scope and never should: modules/heartbeats.md and system/devops-cycle-design.md
# describing the OWNED ship step, modules/testing.md on the ~/.zprofile PATH block,
# modules/llm-adapters.md on what generates CLAUDE.md, system/atomic-capture-hook.md ×3 on
# hook wiring, agents/alex/role.md, shared/insights.md, this repo's own docs-maintenance.md.
# Requiring a scope statement near each would demand ~12 exemptions — "a guard that looks
# tree-wide and holds an allowlist of whatever exists today", which is the design the other
# file rejected in as many words. Asking instead whether the reader is handed a COMMAND
# collapses those 20 mentions to 3, all three of them genuine "here is the command" sites.
#
# NOR A VERB-MOOD CLASSIFIER, same measurement. A third-person rationale cannot be told from
# a directive: system/devops-cycle-design.md:1099 says the docs "no longer drift until
# someone happens to run the installer by hand" — correct, and textually the defect. The
# BARE IMPERATIVE is separable, and only that: "run bin/install-agent-docs" cannot describe a
# pipeline step, while "Runs bin/agent-runtime install" (system/ecosystem-build.md:79,
# system/house-burn-down.md:532) cannot be an instruction. Measured: the imperative sweep
# below draws 0 hits over the live tree and the "Runs" control draws exactly those 2. So it
# is pinned by mutation, not by a live offender.
#
# WHAT THIS DOES NOT COVER — say it here, because the defect that produced this file was a
# guard trusted for more than it held. It sees command PRESENTATIONS and the imperative
# mood. A third-person rationale that talks a reader into a run, naming no command and no
# tree, is caught by nothing in this repo. That is a known, measured hole, not an oversight.
class InstallerCommandScopeTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs/agents")

  # The install spellings, MINUS the read-only subcommands. `check` and `doctor` write
  # nothing and are safe at any time (skills/README.md and system/bootstrap.md both say so),
  # so demanding a bringup scope on them would teach the reader the opposite of the truth.
  INSTALL_CMD = %r{bin/(?:agent-runtime\s+install|install-agent-docs)(?!\s+(?:check|doctor))\b}

  # A fenced line that IS the command — optionally prompt-prefixed, trailing `# comment`
  # allowed. Anchored at the start so a line merely CONTAINING the string in prose inside a
  # fence (a log excerpt, a diff) does not score.
  FENCED_CMD_LINE = /\A[ \t]*(?:\$ )?#{INSTALL_CMD}/
  FENCE_DELIM     = /\A[ \t]*```/

  # The scope that makes exemption 1 legible at the point of use. "bringup" is the word
  # docs-maintenance.md § Editing The Entry Docs now uses for the exemption (it covers a
  # fresh machine AND a single app cloned onto a bare one); "fresh-machine" is the older
  # spelling still carried by skills/README.md and modules/app-registry.md.
  BRINGUP_SCOPE = /fresh[- ]machine|bringup/i

  # How far above the fence a lead-in may sit. THREE NON-BLANK LINES, and the number is
  # load-bearing in both directions. Too small and modules/app-registry.md's "Fresh-machine
  # operator surface:" header (two lines above its fence) stops counting, which would force
  # a fix into a file this task deliberately does not touch. Too large and it swallows
  # system/bootstrap.md's own page intro — line 5 says "a quick single-app bringup" — which
  # would have marked the ORIGINAL defect compliant and left this guard asserting nothing.
  LEAD_IN_LINES = 3

  def live_docs
    Dir.glob(AGENTS.join("**", "*.md")).sort.filter_map do |full|
      rel = Pathname.new(full).relative_path_from(AGENTS).to_s
      # archive/ and audits/ are frozen dated snapshots. The house rule leaves them as
      # written, and archive/audits/autonomous-release-sop-2026-06-27.md:59 shows why the
      # exclusion is not theoretical: it says "run `bin/install-agent-docs install` from the
      # primary". That WAS the instruction in 2026-06; rewriting it would be a lie about the
      # past, and it is unreachable as guidance.
      next if rel.start_with?("archive/", "audits/")

      [rel, File.read(full)]
    end
  end

  # Every fenced install-command line, with the scope text in effect at that line: the line
  # itself plus the lead-in above the block that contains it.
  def fenced_install_commands(body)
    lines  = body.lines
    inside = false
    opener = nil
    found  = []

    lines.each_with_index do |line, idx|
      if line.match?(FENCE_DELIM)
        inside = !inside
        opener = inside ? idx : nil
        next
      end
      next unless inside && line.match?(FENCED_CMD_LINE)

      lead_in = lines[0...opener].reject { |l| l.strip.empty? }.last(LEAD_IN_LINES).join(" ")
      found << { line_no: idx + 1, line: line.rstrip, lead_in: lead_in }
    end
    found
  end

  def scoped?(hit)
    BRINGUP_SCOPE.match?(hit[:line]) || BRINGUP_SCOPE.match?(hit[:lead_in])
  end

  test "every fenced installer command in the docs tree carries its bringup scope" do
    docs = live_docs

    # THE FLOOR. A sweep's value is breadth, and a glob that stops matching turns "every
    # command is scoped" into a statement about an empty set — the failure mode both sibling
    # guards carry a floor against. 123 live docs the day this landed.
    assert_operator docs.length, :>=, 80,
                    "swept only #{docs.length} live agent doc(s) — docs/agents carries 120+. The glob or " \
                    "the archive/audits filter has stopped matching, so this sweep asserts NOTHING. Fix " \
                    "the scan; do not lower this floor."

    hits = docs.flat_map { |rel, body| fenced_install_commands(body).map { |h| h.merge(rel: rel) } }

    # A COUNT FLOOR IS HALF THE GUARD. The three sites are pinned BY NAME because the fence
    # walker is the fragile part: a markdown edit that turns ```bash into an indented block,
    # or an unbalanced fence earlier in the file, silently drops a doc while the doc-count
    # floor above still passes.
    %w[system/bootstrap.md skills/README.md modules/app-registry.md].each do |rel|
      assert_includes hits.map { |h| h[:rel] }, rel,
                      "#{rel} no longer presents a fenced installer command to the sweep. Either the " \
                      "command was removed (then drop this pin), or the FENCE walker broke and this " \
                      "guard is now blind to that file. It is the second one that matters: " \
                      "system/bootstrap.md is the site this whole file was written for."
    end

    unscoped = hits.reject { |h| scoped?(h) }

    assert_empty unscoped.map { |h| "#{h[:rel]}:#{h[:line_no]}" },
                 "These docs hand the reader `bin/agent-runtime install` / `bin/install-agent-docs` as a " \
                 "runnable command without saying it is a BRINGUP-ONLY run. Unscoped, it reads as routine " \
                 "maintenance — and it is not: it publishes GLOBALLY (projects-root AGENTS.md/CLAUDE.md, " \
                 "~/.claude/skills, ~/.codex/skills, ~/.claude/settings.json, /etc/codex/requirements.toml, " \
                 "and an appended ~/.zprofile block), so from a feature worktree it pushes unshipped " \
                 "mid-branch text to every session on the machine. That is the 2026-09-08 incident. Put the " \
                 "scope on the command line (`# BRINGUP ONLY — publishes globally`) or in the prose that " \
                 "introduces the block, per docs/agents/modules/docs-maintenance.md § Editing The Entry " \
                 "Docs, exemption 1."
  end

  test "no live agent doc gives a bare-imperative install directive" do
    docs = live_docs
    assert_operator docs.length, :>=, 80, "the doc sweep collapsed — see the floor above"

    # Emphasis-normalised (mirrors ship_docs_sync_docs_test.rb) so a line-wrapped
    # "run\n`bin/install-agent-docs`" matches as one run.
    offenders = docs.select do |_rel, body|
      imperative_install?(body.gsub(/[*`]/, "").gsub(/\s+/, " "))
    end

    assert_empty offenders.map(&:first),
                 "These docs tell the reader, in the imperative, to run the docs installer. Nobody " \
                 "hand-runs it: the entry docs, the user-global skills, the Claude/Codex hooks and the " \
                 "~/.zprofile block are published by the owned sync_agent_docs step of `bin/release ship`. " \
                 "The only legitimate hand-run is bringup on a machine with no roots — and a bringup doc " \
                 "presents the command in a scoped block (see the sweep above), it does not order a run " \
                 "mid-prose. See docs/agents/modules/docs-maintenance.md § Editing The Entry Docs."
  end

  # The bare imperative only. `run bin/...` cannot describe a pipeline step; `Runs
  # bin/agent-runtime install` (the Phase 5b table rows in system/ecosystem-build.md and
  # system/house-burn-down.md) cannot be an instruction. The `(?<![-\w])` guard is what keeps
  # "auto-runs" and "re-runs" out, and it is the whole precision of this pattern.
  def imperative_install?(flat)
    /(?<![-\w])[Rr]un\s+#{INSTALL_CMD}/.match?(flat)
  end

  # THE SITE THIS FILE WAS FILED FOR, pinned individually. The sweep above catches a verbatim
  # revert of the missing scope, but not the sentence that made the block a directive — and
  # an unexplained deletion is how an instruction gets helpfully added back. So assert the
  # doc still carries the rule it was given, not merely that the old words are gone.
  test "bootstrap scopes its install to bringup instead of inviting a hand-run" do
    body = AGENTS.join("system/bootstrap.md").read
    flat = body.gsub(/[*`]/, "").gsub(/\s+/, " ")

    refute_match(/run it by hand/i, flat,
                 "system/bootstrap.md again invites the reader to run the installer 'by hand' because they " \
                 "only brought up the one app. Single-app bringup IS legitimate (exemption 1 now says so " \
                 "explicitly), but it is legitimate as a ONE-TIME bringup run in a scoped block — not as a " \
                 "by-hand alternative offered next to the automated path, which is the framing that makes a " \
                 "reader reach for it later, from a worktree, to close a drift report.")

    assert_match(/BRINGUP ONLY/i, flat,
                 "system/bootstrap.md's install block lost its scope fence. Unscoped it is exemption 1 " \
                 "being misread as routine — the same defect skills/README.md:31 was fenced against.")
    assert_match(/publishes globally/i, flat,
                 "system/bootstrap.md no longer says the install publishes GLOBALLY. The scope alone tells " \
                 "a reader WHEN; this tells them what it costs to be wrong, and it is the half that " \
                 "survives being skimmed.")
    assert_match(%r{docs-maintenance\.md}, flat,
                 "system/bootstrap.md no longer points at the module that owns the rule. One hop to the " \
                 "registered primitive is the SOP standard, and it is what keeps this doc from having to " \
                 "restate — and drift from — the closed exemption list.")
    assert_match(/ecosystem-build/, flat,
                 "system/bootstrap.md lost the pointer to the whole-machine path. Without it the reader " \
                 "with a genuinely fresh Mac has only the single-app instructions in front of them.")
  end

  # THE POLICY THIS GUARD ENFORCES. The assertions above are only meaningful while
  # docs-maintenance.md actually admits single-app bringup into exemption 1. If that widening
  # is reverted, bootstrap.md's fenced command becomes an unlisted third exemption and this
  # file would be enforcing a scope the policy does not grant — so go RED here instead.
  test "docs-maintenance admits single-app bringup into exemption 1 and still closes the list" do
    flat = AGENTS.join("modules/docs-maintenance.md").read.gsub(/[*`]/, "").gsub(/\s+/, " ")

    assert_match(/Two runs stay legitimate/, flat,
                 "docs-maintenance.md lost the exemption list this guard is scoped to")
    assert_match(/the list is closed/, flat,
                 "docs-maintenance.md no longer closes the exemption list at two — widening exemption 1 to " \
                 "cover single-app bringup was meant to keep the list CLOSED, not to open a third slot")
    assert_match(/single app cloned onto a bare machine|single-app bringup is inside it/i, flat,
                 "docs-maintenance.md's exemption 1 no longer covers the one-app case. That widening is " \
                 "what makes system/bootstrap.md's fenced install legitimate rather than a fourth sibling " \
                 "in the installer-prescription family; without it, this guard scopes a run the policy " \
                 "does not allow at all.")
    assert_match(%r{test/docs/installer_command_scope_test\.rb}, flat,
                 "docs-maintenance.md no longer names this guard. The defect that produced the sibling " \
                 "guard's widening was a limit nobody could find from the module — state the coverage " \
                 "where the policy lives.")
  end

  # MUTATION PROOF — the detectors are not decoration. Run the SAME predicates the sweeps use
  # over bodies shaped like the defect and like the correct text. The imperative sweep draws
  # ZERO live hits today, so without this it would be an assertion about an empty set.
  test "the fenced-command detector fires on the unscoped block and spares a scoped one" do
    defect = <<~MD
      Install (or re-sync) both in one idempotent command:

      ```bash
      bin/agent-runtime install       # AGENTS.md + CLAUDE.md, skills, Codex hooks
      ```
    MD
    scoped_inline = <<~MD
      ```bash
      bin/agent-runtime install       # FRESH-MACHINE BRINGUP ONLY — publishes globally
      ```
    MD
    scoped_lead_in = <<~MD
      Fresh-machine operator surface:

      ```bash
      bin/agent-runtime install
      ```
    MD
    read_only = <<~MD
      ```bash
      bin/install-agent-docs check
      bin/agent-runtime doctor
      ```
    MD
    prose_only = "The root `CLAUDE.md` adapter is generated by `bin/agent-runtime install`.\n"

    hit = fenced_install_commands(defect)
    assert_equal 1, hit.length, "the walker missed the fenced install command — the exact block " \
                                "system/bootstrap.md carried at :24-27"
    refute scoped?(hit.first), "the scope check PASSED an unscoped block — this is the assertion the " \
                               "whole file rests on, and a BRINGUP_SCOPE that matches everything would " \
                               "leave the sweep green forever"

    assert scoped?(fenced_install_commands(scoped_inline).first),
           "the scope check failed skills/README.md:31, the site that is already correct — a guard that " \
           "reds on compliant text gets its rule deleted rather than obeyed"
    assert scoped?(fenced_install_commands(scoped_lead_in).first),
           "the scope check failed a block scoped by its LEAD-IN prose (modules/app-registry.md:94-97). " \
           "Requiring the scope inline would force a fix into a file this task deliberately leaves alone."

    assert_empty fenced_install_commands(read_only),
                 "the walker scored `check`/`doctor` — those write nothing and are safe at any time, so " \
                 "demanding a bringup scope on them would teach the reader the opposite of the truth"
    assert_empty fenced_install_commands(prose_only),
                 "the walker scored a PROSE mention outside any fence. That is the ~14-mention base rate " \
                 "this predicate exists to avoid; scoring it turns this into the any-mention sweep that " \
                 "cannot work under system/ and modules/."
  end

  test "the imperative detector fires on a directive and spares the Phase 5b description" do
    assert imperative_install?("When the doc changes, run bin/install-agent-docs from this checkout."),
           "the detector missed a bare-imperative install directive — the shape that names no tree and so " \
           "scores zero on both sibling guards"
    assert imperative_install?("Run bin/agent-runtime install first."),
           "the detector missed the sentence-initial imperative"

    refute imperative_install?("| 5b. Agent runtime | Runs bin/agent-runtime install, which installs both entrypoints |"),
           "the detector fired on the Phase 5b table row in system/ecosystem-build.md and " \
           "system/house-burn-down.md — correct DESCRIPTION of a pipeline step. Scoring it would force " \
           "exemptions onto the two docs that legitimately document bringup."
    refute imperative_install?("Post-ship, ship auto-runs bin/install-agent-docs from the ship workspace."),
           "the detector fired on modules/heartbeats.md's description of the OWNED step — the exact pair " \
           "the sibling guard measured as inseparable by verb mood. The (?<![-\\w]) guard is what keeps " \
           "'auto-runs' out; losing it collapses this predicate."
    refute imperative_install?("Verify with bin/install-agent-docs check at any time."),
           "the detector fired on the read-only check"
  end
end
