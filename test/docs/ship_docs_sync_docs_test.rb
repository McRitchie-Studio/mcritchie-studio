# frozen_string_literal: true

require "test_helper"

# Tripwire for the OWNED post-ship agent-docs sync (name-install-agent-docs-owner):
# `bin/release ship` auto-runs bin/install-agent-docs as its last step, and the ship
# runbook NAMES the owner (Steffon) so installed-docs drift after an adapter/skill/SOP
# merge is somebody's problem, not nobody's. Drop the step or its documented owner and
# these fail.
#
# The step's SOURCE TREE is the second claim this file holds (ship-doc-names-wrong-tree).
# The installer syncs from its own root, so the tree it runs in IS the docs it publishes,
# and `sync_agent_docs` takes that root from the hub's SHIP WORKSPACE
# (`.worktrees/_ship`, pinned at the SHA that just shipped) — falling back to the primary
# only when that workspace holds no installer. `restore_primaries` runs first and is
# best-effort by design (it refuses a primary holding a live session's work), so the
# primary can sit a release behind: naming it as the source is not a synonym, it is the
# wrong tree. See the section below the existing tests.
class ShipDocsSyncDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read (mirrors review_lane_docs_test.rb): drop
  # * and ` and collapse whitespace so a line-wrapped phrase matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] the ship runbook documents the post-ship agent-docs sync and its owner" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/post-ship agent-docs sync/i, body,
      "the ship building block documents the owned bin/install-agent-docs run")
    assert_match(/post-ship agent-docs sync[^|]{0,900}owner: steffon/im, body,
      "the sync step names its owner (Steffon) in the ship runbook")
    assert_match(/non-fatal/i, body, "the sync is documented as non-fatal — it never aborts a completed ship")
  end

  test "[static] the production-deploy act (heartbeats) carries the docs-sync step" do
    body = norm("modules/heartbeats.md")
    assert_match(/post-ship agent-docs sync[^.]{0,300}install-agent-docs/im, body,
      "Act 1 (production-deploy) lists the docs-sync step")
    assert_match(/steffon owns this step/i, body, "the act names Steffon as the step's owner")
  end

  test "[static] the canonical production-deploy SOP (Avi) carries the docs-sync step" do
    body = norm("agents/steffon/sops/production-deploy.md")
    assert_match(/post-ship[^.]{0,200}install-agent-docs/im, body,
      "the SOP documents the post-ship installer run (relocated from the retired qa-release SKILL)")
    assert_match(/steffon owns the step/i, body, "the SOP names Steffon as the step's owner")
    assert_match(/non-fatal/i, body, "the SOP states the sync never aborts a completed ship")
  end

  test "[static] bin/release ship wires sync_agent_docs after restore_primaries" do
    src = File.read(Rails.root.join("bin", "release.rb"))
    restore_at = src.index("restore_primaries(app_groups)")
    sync_at    = src.index("sync_agent_docs\n")
    assert restore_at && sync_at, "ship must call both restore_primaries and sync_agent_docs"
    assert_operator restore_at, :<, sync_at,
      "the docs sync runs AFTER the primaries are restored to the shipped main"
  end

  # --- the installer's SOURCE tree: ship workspace, primary as fallback ------
  #
  # WHAT WENT WRONG (ship-doc-names-wrong-tree, 2026-09-08). The production-deploy SOP
  # said the ship auto-runs "the hub primary's" `bin/install-agent-docs`, and told a
  # reader whose sync warned to run the installer "from the hub primary by hand". Both
  # name the wrong tree. `modules/docs-maintenance.md` already stated it correctly, so
  # two live docs disagreed and the code agreed with the other one. `modules/heartbeats.md`
  # and `modules/zap-protocol.md` carried the same claim; the sweep below is how they were
  # found, and is what a grep for the one reported sentence would have missed.
  #
  # WHY THIS IS NOT PEDANTRY, and why it earns a guard. Installing from the ship workspace
  # is what publishes THE TREE THAT SHIPPED. A reader who believes it installs from the
  # primary concludes that a dirty or lagging primary corrupts what gets published — and
  # then "fixes" it by hand-running the installer, which is the exact behaviour PR #1291
  # shipped a preflight message to stop, and which does not CLOSE drift but MOVES it (every
  # other session's preflight goes red). The wrong sentence recreates the defect its
  # neighbour was written to prevent.
  #
  # WHY THE CODE HALF IS ASSERTED STRUCTURALLY AND THE BEHAVIOUR HALF IS NOT RE-RUN HERE.
  # The runnable proof of the branch already exists and is BEHAVIOURAL, not textual:
  # test/lib/release_cli_test.rb `load`s bin/release.rb in a subprocess, stubs
  # Release::GateWorkspace.path, and asserts the ARGV the installer is actually shelled
  # with — once with a workspace present, once without. Re-executing that harness from a
  # Rails-loaded docs test would duplicate a slow subprocess for no new information. So
  # this file asserts the ORDER of the two root assignments (which tree is the source and
  # which is the rescue) and PINS those two behavioural tests by name, so the executable
  # half cannot quietly leave the suite while the docs keep citing it.
  BEHAVIOURAL_PINS = %w[
    test_sync_agent_docs_installs_from_the_shipped_ship_workspace
    test_sync_agent_docs_falls_back_to_the_primary_without_a_ship_workspace
  ].freeze

  # Two spellings of ONE false claim — "the installer's source tree is the primary" —
  # read over the emphasis-normalised body so a line-wrapped sentence matches as one run.
  # `[^.]` keeps each match inside a sentence, which is what stops the many legitimate
  # "Run this SOP from the McRitchie Studio primary checkout" lines from scoring.
  # Measured against the 120+ live docs the day this landed: zero false positives.
  PRIMARY_AS_SOURCE = [
    /(?:hub|McRitchie Studio) primary'?s?[^.]{0,80}?install-agent-docs/i,
    /(?:install-agent-docs|the installer)[^.]{0,60}?from the (?:hub |McRitchie Studio )?primary/i
  ].freeze

  # An ALLOWANCE, not an expectation. This file carries the same wrong-tree claim and owes
  # the same fix; it was held out of the correcting diff because another session was editing
  # it that day, and two sessions editing one doc is a merge conflict, not a sweep. Deliberately
  # asymmetric: the sweep below SKIPS these paths, it does not assert they are still wrong —
  # a test that demands a doc stay broken reddens whoever fixes it. So fixing it passes, and
  # the row is then dead weight to delete.
  GRANDFATHERED = {
    "system/devops-cycle-design.md" =>
      "same claim at :1091 ('the hub primary's bin/install-agent-docs') and :1103 ('the fix is " \
      "running bin/install-agent-docs from the hub primary by hand'); owed a follow-up as of " \
      "2026-09-08. Fix it and delete this row."
  }.freeze

  # Every live agent doc, emphasis-normalised. `archive/` and `audits/` are frozen dated
  # snapshots — the house rule leaves them as written, and correcting a 2026-06 audit's
  # record of what was true then would be a lie about the past, not a fix.
  def live_docs
    Dir.glob(AGENTS.join("**", "*.md")).sort.filter_map do |full|
      rel = Pathname.new(full).relative_path_from(AGENTS).to_s
      next if rel.start_with?("archive/", "audits/")

      [rel, File.read(full).gsub(/[*`]/, "").gsub(/\s+/, " ")]
    end
  end

  def names_primary_as_source?(body)
    PRIMARY_AS_SOURCE.any? { |rx| rx.match?(body) }
  end

  test "[static] sync_agent_docs roots the installer in the ship workspace, primary only as fallback" do
    src = File.read(Rails.root.join("bin", "release.rb"))
    body = src[/^def sync_agent_docs$.*?^end$/m]
    assert body, "bin/release.rb no longer defines sync_agent_docs at the top level — the docs " \
                 "corrected by ship-doc-names-wrong-tree describe this method by name"

    workspace_at = body.index(/root\s*=\s*Release::GateWorkspace\.path\(.*role:\s*"ship"\)/)
    fallback_at  = body.index(/root\s*=\s*repo_path\("mcritchie-studio"\)\s+unless\s+File\.exist\?/)

    assert workspace_at,
           "sync_agent_docs no longer takes its root from the hub's SHIP WORKSPACE " \
           "(Release::GateWorkspace.path(..., role: \"ship\")). Three live docs now state that it " \
           "does — modules/docs-maintenance.md, agents/steffon/sops/production-deploy.md and " \
           "modules/heartbeats.md. Change the code and those docs go stale in the same breath."
    assert fallback_at,
           "sync_agent_docs no longer falls back to the primary when the ship workspace holds no " \
           "installer. The docs state the fallback as REAL; drop it and they overclaim."
    assert_operator workspace_at, :<, fallback_at,
                    "the primary is assigned BEFORE the ship workspace in sync_agent_docs — the source " \
                    "and the fallback have swapped. That inverts what production-deploy.md, " \
                    "heartbeats.md and docs-maintenance.md tell every ship operator."

    assert_match(/installer\s*=\s*File\.join\(root,/, body,
                 "the installer path is no longer built from `root`, so the workspace-vs-primary " \
                 "choice above no longer decides which tree publishes the docs")
  end

  test "[static] the behavioural proof of the installer source is still in the suite" do
    body = File.read(Rails.root.join("test", "lib", "release_cli_test.rb"))

    BEHAVIOURAL_PINS.each do |name|
      assert_includes body, "def #{name}",
                      "test/lib/release_cli_test.rb no longer defines #{name}. That subprocess test is " \
                      "the RUNNABLE half of this claim — it stubs GateWorkspace.path and asserts the " \
                      "installer ARGV — and the structural test above deliberately does not duplicate " \
                      "it. If you renamed it, rename it here; if you deleted it, this file is now the " \
                      "only thing holding a claim nothing executes."
    end
  end

  test "[static] no live agent doc names the primary as the installer's source tree" do
    docs = live_docs

    # THE FLOOR. A sweep's whole value is breadth, and a glob that stops matching turns
    # "no doc names the wrong tree" into a statement about an empty set. 121 live docs the
    # day this landed.
    assert_operator docs.length, :>=, 80,
                    "swept only #{docs.length} live agent doc(s) — docs/agents carries 120+. The glob " \
                    "or the archive/audits filter has stopped matching, so this sweep is asserting " \
                    "NOTHING. Fix the scan; do not lower this floor."

    # A count floor alone is half the guard: it survives losing exactly the docs that carry
    # the claim. Pin the three corrected files by name.
    %w[agents/steffon/sops/production-deploy.md modules/heartbeats.md modules/zap-protocol.md].each do |rel|
      assert_includes docs.map(&:first), rel,
                      "#{rel} dropped out of the sweep — it is one of the three files this guard was " \
                      "written for, so its absence is the failure mode, not a passing run"
    end

    offenders = docs.select { |rel, body| names_primary_as_source?(body) && !GRANDFATHERED.key?(rel) }

    assert_empty offenders.map(&:first),
                 "These docs say the post-ship installer runs from the PRIMARY. It runs from the hub's " \
                 "ship workspace (.worktrees/_ship, pinned at the shipped SHA) and falls back to the " \
                 "primary only when that workspace holds no installer — see sync_agent_docs in " \
                 "bin/release.rb and modules/docs-maintenance.md § Editing The Entry Docs. The wrong " \
                 "tree is not a synonym: it tells a reader that a lagging primary corrupts what is " \
                 "published, and the next thing that reader does is hand-run the installer."

    GRANDFATHERED.each_key do |rel|
      assert AGENTS.join(rel).exist?,
             "#{rel} is grandfathered out of this sweep but no longer exists — the row is dead. " \
             "Delete it, or point it at wherever that prose moved."
    end
  end

  test "[static] the ship-sync docs name the workspace as source and the primary as fallback" do
    %w[agents/steffon/sops/production-deploy.md modules/heartbeats.md].each do |rel|
      body = norm(rel)

      assert_match(/install-agent-docs[^.]{0,120}?ship workspace/i, body,
                   "#{rel} no longer names the SHIP WORKSPACE as the tree the post-ship installer runs " \
                   "from. That is the whole point of the step: it publishes the tree that shipped.")
      assert_match(/primary[^.]{0,60}?fallback|fallback[^.]{0,60}?primary/i, body,
                   "#{rel} no longer states that the primary is the FALLBACK. Omitting it is the other " \
                   "way to be wrong: bin/release.rb does drop back to the primary, so a doc that denies " \
                   "it looks wrong to anyone who reads the code — and they then distrust the corrected " \
                   "half too.")
    end
  end

  # MUTATION PROOF: the detector is not inert. Run the SAME predicate the sweep uses over the
  # exact sentences this task removed, and over the ones that replaced them. A guard that
  # cannot fail on the reintroduced defect is decoration.
  test "the wrong-tree detector fires on the sentences this task removed" do
    sop = "Post-ship, bin/release ship auto-runs the hub primary's bin/install-agent-docs " \
          "(non-fatal — it never aborts a completed ship; Steffon owns the step and its mechanism) " \
          "so the installed agent docs (~/.claude + ~/.codex skills, the projects-root " \
          "AGENTS.md/CLAUDE.md) match what shipped."
    by_hand = "If it warns, run the installer from the hub primary by hand."
    zap = "Changes to it — like all agent-doc changes — reach the generated projects-root " \
          "AGENTS.md and adapters only after bin/install-agent-docs runs from the McRitchie " \
          "Studio primary checkout."

    fixed = "Post-ship, bin/release ship auto-runs bin/install-agent-docs from the hub's ship " \
            "workspace (mcritchie-studio/.worktrees/_ship, the tree pinned at the SHA that just " \
            "shipped), so the installed agent docs (~/.claude + ~/.codex skills, the projects-root " \
            "AGENTS.md/CLAUDE.md) are published from exactly what shipped."
    fallback = "The hub primary is the fallback, not the source: sync_agent_docs drops back to it " \
               "only when the ship workspace holds no installer (a ship that resolved no hub member)"
    unrelated = "Run this SOP from the McRitchie Studio primary checkout, under the deployer identity"

    assert names_primary_as_source?(sop), "the detector missed the possessive attribution — the exact " \
                                          "shape production-deploy.md carried at :507"
    assert names_primary_as_source?(by_hand), "the detector missed the by-hand directive at :511, the " \
                                              "half that actually tells a reader to run the wrong tree"
    assert names_primary_as_source?(zap), "the detector missed zap-protocol.md's spelling of the same " \
                                          "claim, which uses neither 'hub' nor a possessive"

    refute names_primary_as_source?(fixed), "the detector fires on the CORRECTED sentence — it would " \
                                            "force a grandfather row for stating the fact right"
    refute names_primary_as_source?(fallback), "the detector fires on prose that correctly calls the " \
                                               "primary a FALLBACK, which every corrected doc must say"
    refute names_primary_as_source?(unrelated), "the detector fires on 'run this SOP from the primary " \
                                                "checkout' — that line opens most SOPs in the tree and " \
                                                "has nothing to do with the installer"
  end
end
