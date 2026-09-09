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
  # THE FIFTH SITE (cycle-doc-prescribes-hand-install, 2026-09-09).
  # `system/devops-cycle-design.md` carried the same claim twice and was GRANDFATHERED out
  # of the sweep above, because another session held the file that day. It has since been
  # corrected and the exemption is gone — the file is swept like every other, and is now
  # PINNED by name below. Two things that fix taught this guard:
  #   * It carried a THIRD shape the sweep could not see — a rationale, not a directive.
  #     Hence the third pattern; see PRIMARY_AS_SOURCE.
  #   * The by-hand half is not hypothetical. On 2026-09-08 it was copied into a builder
  #     brief, the builder ran the installer from a WORKTREE, and because these docs publish
  #     GLOBALLY it pushed unshipped mid-branch text to every session on the machine. It was
  #     caught and re-synced the same day. The doc is where the instruction came from.
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
  # which is the fallback) and PINS those two behavioural tests by name, so the executable
  # half cannot quietly leave the suite while the docs keep citing it.
  #
  # Name the fallback precisely: it is a GUARD CLAUSE (`root = primary unless File.exist?`),
  # not a rescue. `sync_agent_docs` also has a `rescue StandardError`, and that is a
  # different mechanism — the non-fatal skip that keeps a docs sync from failing an
  # already-completed ship. Calling the fallback "the rescue" merges the two, and a doc
  # written from that reading describes a fallback that fires on error rather than on a
  # missing installer.
  BEHAVIOURAL_PINS = %w[
    test_sync_agent_docs_installs_from_the_shipped_ship_workspace
    test_sync_agent_docs_falls_back_to_the_primary_without_a_ship_workspace
    test_sync_agent_docs_rescue_names_an_absolute_installer_after_resolution
    test_sync_agent_docs_rescue_names_an_absolute_installer_before_resolution
  ].freeze

  # Three spellings of ONE false claim — "the installer's source tree is the primary" —
  # read over the emphasis-normalised body so a line-wrapped sentence matches as one run.
  # `[^.]` keeps each match inside a sentence, which is what stops the many legitimate
  # "Run this SOP from the McRitchie Studio primary checkout" lines from scoring.
  # Measured against the live docs each time a pattern was added: zero false positives
  # (120+ for the first two, 122 for the third).
  #
  # The THIRD pattern was added by cycle-doc-prescribes-hand-install, and the reason is
  # worth keeping: the first two catch DIRECTIVES ("the hub primary's install-agent-docs",
  # "run it from the hub primary"), and system/devops-cycle-design.md carried a third shape
  # this sweep did not see — a RATIONALE. It explained the step's post-ship placement by
  # saying "the installer reads the LOCAL hub checkout's docs, and only after the ff
  # release → main + restore does the primary's main hold the merged docs". Measured: the
  # two original patterns MISS that sentence. It is the most dangerous of the three,
  # because a reader who accepts an explanation reasons their way to the hand-run instead
  # of merely being told to do it — so a sweep that only catches instructions catches the
  # symptom and leaves the cause. The pattern targets the family ("the installer reads the
  # <hub|primary> checkout"), not that one sentence.
  PRIMARY_AS_SOURCE = [
    /(?:hub|McRitchie Studio) primary'?s?[^.]{0,80}?install-agent-docs/i,
    /(?:install-agent-docs|the installer)[^.]{0,60}?from the (?:hub |McRitchie Studio )?primary/i,
    /(?:install-agent-docs|the installer)[^.]{0,60}?reads the[^.]{0,40}?(?:hub|primary)/i
  ].freeze

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

  # --- EVERY warn branch must hand over an ABSOLUTE path --------------------
  # (rescue-warn-omits-installer-path)
  #
  # WHAT WENT WRONG. sync_agent_docs emits TWO warn lines and only one was safe to act
  # on. The `unless ok` branch interpolated the resolved `installer` — absolute, correct.
  # The `rescue StandardError` branch printed a BARE `bin/install-agent-docs`, which
  # resolves against whatever directory the reader is sitting in. The recovery line the
  # docs now carry — "run the installer path the warn line prints" — is exactly right
  # against the first branch and meaningless against the second.
  #
  # WHY THIS SURFACE EARNS A GUARD. bin/install-agent-docs is 1000+ lines and PUBLISHES
  # GLOBALLY: the projects-root AGENTS.md/CLAUDE.md, ~/.claude + ~/.codex skills,
  # ~/.claude/settings.json, /etc/codex/requirements.toml, and an APPEND to ~/.zprofile
  # (whose own comment notes nothing keeps a reflog for it). On 2026-09-08 a builder
  # followed a prescription like this from a feature worktree and published unshipped
  # mid-branch text to every session on the machine. A warn line that hands over a
  # cwd-relative path is one `cd` from repeating that.
  #
  # WHAT THIS FILE ASSERTS, AND WHAT IT DELIBERATELY DOES NOT. Statically we can prove
  # two things: that no warn branch hard-codes a command (each interpolates a local), and
  # that the local is SEEDED with an absolute path before the first line that can raise.
  # The second half is what makes the first half worth anything, and it is not pedantry:
  # the `rescue` is METHOD-LEVEL, so it also covers the three lines that resolve `root`.
  # Ruby defines a local at the parser's first sight of its assignment, so on an early
  # raise `installer` is IN SCOPE BUT NIL — and a naive "interpolate #{installer}" fix
  # renders "run `` by hand", an empty backtick pair strictly worse than the bare name.
  #
  # A source scan cannot tell a nil interpolation from a good one. That half is proved by
  # EXECUTION, in test/lib/release_cli_test.rb, which loads bin/release.rb in a subprocess
  # and drives sync_agent_docs with the raise placed on BOTH sides of the resolution. Both
  # tests are pinned by name in BEHAVIOURAL_PINS above, so the runnable half cannot quietly
  # leave the suite while this file keeps asserting the shape.

  def sync_agent_docs_body
    src = File.read(Rails.root.join("bin", "release.rb"))
    src[/^def sync_agent_docs$.*?^end$/m]
  end

  # [line, backticked command] for every warn branch in a sync_agent_docs body. Takes the
  # body as an argument so the mutation proof below runs THIS extraction over the reverted
  # source, rather than a lookalike written to agree with it.
  def warn_commands_in(body)
    body.lines.select { |line| line.include?("⚠") }
        .map { |line| [line.strip, line[/`([^`]*)`/, 1]] }
  end

  # A by-hand command is acceptable only as a bare interpolation of a local — `#{installer}`.
  # A literal cannot be absolute-by-construction across machines, and a literal with an
  # interpolated PREFIX (`#{root}/bin/...`) sidesteps the seeded variable this guard tracks.
  def interpolated_command?(command)
    command.to_s.match?(/\A#\{[a-z_][a-z0-9_]*\}\z/)
  end

  test "[static] every warn branch in sync_agent_docs hands over an interpolated installer path" do
    body = sync_agent_docs_body
    assert body, "bin/release.rb no longer defines sync_agent_docs at the top level"

    warns = warn_commands_in(body)
    assert_operator warns.length, :>=, 2,
                    "sync_agent_docs used to carry TWO warn branches (the `unless ok` failure and the " \
                    "`rescue StandardError` skip) and this guard found #{warns.length}. If a branch was " \
                    "removed, say so here; if the warn marker changed, this scan is now asserting " \
                    "nothing. Do not lower this floor."

    warns.each do |line, command|
      assert command,
             "a warn branch in sync_agent_docs offers no backticked by-hand command:\n  #{line}\n" \
             "Every warn in this method is an operator's recovery instruction — it must name the " \
             "installer to run."
      assert interpolated_command?(command),
             "a warn branch prescribes `#{command}`, a hard-coded command:\n  #{line}\n" \
             "It must interpolate the resolved installer path instead. A bare `bin/install-agent-docs` " \
             "resolves against the READER's cwd, and this installer publishes GLOBALLY — that is how " \
             "unshipped worktree text reached every session on this machine on 2026-09-08."
    end

    names = warns.map { |_line, command| command[/\A#\{([a-z_][a-z0-9_]*)\}\z/, 1] }.uniq
    assert_equal ["installer"], names,
                 "the warn branches interpolate #{names.inspect}. This guard tracks ONE variable — the " \
                 "`installer` seeded absolute below — and can only prove the seed covers a name it knows. " \
                 "If you renamed it, rename it here and in test/lib/release_cli_test.rb."
  end

  test "[static] sync_agent_docs seeds an absolute installer path before anything that can raise" do
    body = sync_agent_docs_body
    assert body, "bin/release.rb no longer defines sync_agent_docs at the top level"

    seed_at  = body.index(/installer\s*=\s*File\.expand_path\("install-agent-docs",\s*__dir__\)/)
    risky_at = body.index(/Release::GateWorkspace\.path\(/)

    assert seed_at,
           "sync_agent_docs no longer seeds `installer` with File.expand_path(\"install-agent-docs\", " \
           "__dir__). That seed is the only reason the rescue's interpolation cannot be nil: the rescue " \
           "is METHOD-LEVEL, so it also covers the lines that resolve `root`, and Ruby leaves a local " \
           "declared-but-nil when its assignment never ran. Without the seed the rescue prints " \
           "\"run `` by hand\" — an empty backtick pair, worse than the bare command it replaced."
    assert risky_at, "sync_agent_docs no longer calls Release::GateWorkspace.path — this ordering check " \
                     "has lost the landmark it measures against"
    assert_operator seed_at, :<, risky_at,
                    "the installer seed now comes AFTER Release::GateWorkspace.path. Everything between " \
                    "the top of the method and the seed is unprotected: a raise there reaches the rescue " \
                    "with `installer` still nil. The seed must be the first thing the body does."

    assert_match(/File\.expand_path\("install-agent-docs",\s*__dir__\)/, body,
                 "the seed must be absolute BY CONSTRUCTION. __dir__ is bin/release.rb's own directory, " \
                 "where the installer is its sibling, and it cannot itself raise — a seed that calls " \
                 "repo_path or GateWorkspace would be inside the blast radius it exists to survive.")
  end

  # MUTATION PROOF: run the SAME extraction and predicate over the code as it stood before
  # this fix, and as it stands after. A guard that cannot fail on the reintroduced defect is
  # decoration — and this one has a specific blind spot worth stating, so the third case
  # pins it rather than pretending otherwise.
  test "the warn-branch scan fires on the bare command this task removed" do
    before = <<~RUBY
      def sync_agent_docs
        installer = File.join(root, "bin", "install-agent-docs")
        say("  ⚠ agent-docs install failed — run `\#{installer}` by hand (the ship already succeeded)") unless ok
      rescue StandardError => e
        say("  ⚠ agent-docs install skipped (\#{e.message}) — run `bin/install-agent-docs` by hand (the ship already succeeded)")
      end
    RUBY

    after = <<~RUBY
      def sync_agent_docs
        installer = File.expand_path("install-agent-docs", __dir__)
        say("  ⚠ agent-docs install failed — run `\#{installer}` by hand (the ship already succeeded)") unless ok
      rescue StandardError => e
        say("  ⚠ agent-docs install skipped (\#{e.message}) — run `\#{installer}` by hand (the ship already succeeded)")
      end
    RUBY

    before_commands = warn_commands_in(before).map(&:last)
    after_commands  = warn_commands_in(after).map(&:last)

    assert_equal ["\#{installer}", "bin/install-agent-docs"], before_commands,
                 "the extraction no longer sees both warn branches — it is the scan that is broken, " \
                 "not the code under it"
    refute interpolated_command?(before_commands.last),
           "the predicate ACCEPTS the bare `bin/install-agent-docs` the rescue branch used to print. " \
           "That is the whole defect: relax this and the guard passes on the reintroduced bug."
    assert interpolated_command?(before_commands.first),
           "the predicate rejects the `unless ok` branch, which was always correct — it would have " \
           "forced a needless change to the one line that had it right"

    assert after_commands.all? { |command| interpolated_command?(command) },
           "the predicate rejects the CORRECTED method, so the fix could not satisfy its own guard"

    # THE BLIND SPOT, pinned so nobody mistakes this scan for the whole proof. The naive fix
    # — interpolate `installer` in the rescue WITHOUT seeding it — passes here, because a
    # source scan cannot see that the local is nil at that moment. It is caught by execution,
    # in test/lib/release_cli_test.rb's
    # test_sync_agent_docs_rescue_names_an_absolute_installer_before_resolution.
    naive = after.sub(/installer = File\.expand_path.*\n/, "  root = Release::GateWorkspace.path(x)\n")
    assert warn_commands_in(naive).map(&:last).all? { |command| interpolated_command?(command) },
           "sanity: this scan is expected to PASS the unseeded naive fix. If it now fails, the static " \
           "guard has grown teeth it does not actually have, and the comment above is wrong."
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
    %w[
      agents/steffon/sops/production-deploy.md
      modules/heartbeats.md
      modules/zap-protocol.md
      system/devops-cycle-design.md
    ].each do |rel|
      assert_includes docs.map(&:first), rel,
                      "#{rel} dropped out of the sweep — it is one of the four files this guard was " \
                      "written for, so its absence is the failure mode, not a passing run. The doc " \
                      "count floor above does NOT catch this: a glob break that drops all of system/ " \
                      "still clears 80."
    end

    offenders = docs.select { |_rel, body| names_primary_as_source?(body) }

    assert_empty offenders.map(&:first),
                 "These docs say the post-ship installer runs from the PRIMARY. It runs from the hub's " \
                 "ship workspace (.worktrees/_ship, pinned at the shipped SHA) and falls back to the " \
                 "primary only when that workspace holds no installer — see sync_agent_docs in " \
                 "bin/release.rb and modules/docs-maintenance.md § Editing The Entry Docs. The wrong " \
                 "tree is not a synonym: it tells a reader that a lagging primary corrupts what is " \
                 "published, and the next thing that reader does is hand-run the installer."
  end

  test "[static] the ship-sync docs name the workspace as source and the primary as fallback" do
    %w[
      agents/steffon/sops/production-deploy.md
      modules/heartbeats.md
      system/devops-cycle-design.md
    ].each do |rel|
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

  # MUTATION PROOF, second wave: the three sentences cycle-doc-prescribes-hand-install
  # removed from system/devops-cycle-design.md, and the prose that replaced them. The
  # RATIONALE is the one that earned the third pattern — it was measured MISSED by the
  # original two, which is why that file could carry the claim while the sweep ran green
  # over the other four docs.
  test "the wrong-tree detector fires on the cycle-design sentences, RATIONALE included" do
    possessive = "After the primaries are restored to the freshly shipped main, ship auto-runs the " \
                 "hub primary's bin/install-agent-docs (sync_agent_docs, ship step 7b)"
    rationale  = "It is post-SHIP by design — the installer reads the LOCAL hub checkout's docs, and " \
                 "only after the ff release → main + restore does the primary's main hold the merged docs"
    by_hand    = "If the step warns, the fix is running bin/install-agent-docs from the hub primary by hand."

    assert names_primary_as_source?(possessive),
           "the detector missed devops-cycle-design.md's possessive attribution at :1091"
    assert names_primary_as_source?(rationale),
           "the detector missed the RATIONALE at :1096 — the sentence that EXPLAINS the wrong premise " \
           "instead of merely stating it. The two original patterns match directives only, and this " \
           "sentence is a directive-free explanation, so it swept green while being the most dangerous " \
           "of the three. Removing the third pattern reopens exactly that hole."
    assert names_primary_as_source?(by_hand),
           "the detector missed the by-hand prescription at :1103 — the half a builder actually acted " \
           "on from a worktree on 2026-09-08, publishing unshipped text machine-wide"

    # The replacements. Each must pass, or the fix could not have been written.
    source   = "ship auto-runs bin/install-agent-docs (sync_agent_docs, ship step 7b) from the hub's " \
               "ship workspace (mcritchie-studio/.worktrees/_ship, the tree pinned at the frozen SHA " \
               "that just shipped)"
    guard    = "sync_agent_docs takes the workspace root first, then drops back to the primary in a " \
               "guard clause (unless File.exist? on the workspace's installer)"
    recovery = "If the step warns, run the installer path the warn line prints"
    why      = "It is post-SHIP by design: the step publishes only what actually shipped, so a " \
               "qa-release-time or prepare-time run would publish a candidate that has not gone to " \
               "production and may never"

    refute names_primary_as_source?(source), "the detector fires on the corrected SOURCE sentence"
    refute names_primary_as_source?(guard),
           "the detector fires on prose describing the primary FALLBACK as a guard clause — every " \
           "corrected doc owes that half, because bin/release.rb really does drop back to the primary"
    refute names_primary_as_source?(recovery),
           "the detector fires on the corrected recovery line, which points at the path the warn " \
           "line prints rather than at a tree"
    refute names_primary_as_source?(why),
           "the detector fires on the corrected post-ship RATIONALE — the replacement for the " \
           "sentence above must be able to pass this sweep"
  end
end
