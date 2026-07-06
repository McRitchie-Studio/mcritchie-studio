# frozen_string_literal: true

require "test_helper"

# Guard for the review-lane SOP (3-level supervisor hierarchy, 2026-07-06): the
# session Pokémon → Avi the SUPERVISOR (a thin gate that NEVER reviews the code)
# → the domain experts. Avi picks the pair (bin/reviewer-select) and SPAWNS both
# the PRIMARY and LIGHT reviewers IN PARALLEL as sibling children (NOT the old
# "primary spawns the light" nested chain), collects both verdicts, and gates.
# And — since move-release-assembly-to-steffon (2026-07-03) — review is
# REVIEW-ONLY: the merge belongs to Steffon's self-healing qa-release sweep, which
# flips members assembled on QA-green. These assertions are deliberate tripwires:
# revert the model and they fail.
class ReviewLaneDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read: drop * and ` so bold/italic/code emphasis
  # can't break a phrase match, and collapse whitespace so a line-wrapped sentence
  # still matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] avi role.md frames Avi as the review SUPERVISOR who spawns both experts in parallel and never reviews" do
    body = norm("agents/avi/role.md")
    assert_match(/primary reviewer/i, body, "the PRIMARY reviewer is named")
    assert_match(/supervisor/i, body, "Avi is the review SUPERVISOR, not a reviewer")
    assert_match(/never[^.\n]{0,40}review/i, body, "Avi never reviews the code himself")
    assert_match(/parallel/i, body, "Avi spawns the primary and light IN PARALLEL")
    refute_match(/spawns?\s+the\s+light/i, body,
      "the primary must NOT spawn the light — Avi spawns both in parallel (siblings)")
    refute_match(/nested chain/i, body, "review is no longer a nested chain")
    assert_match(/thin/i, body, "Avi's review role is a thin gate")
    refute_match(/\bheavy\b/i, body, "the heavy→primary rename must not regress in the docs")
  end

  test "[static] the devops-cycle runbook gives the merge to Steffon's sweep — review is review-only" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/review-only/i, body, "review stops at reviewed — the 2026-07-03 contract")
    assert_match(/self-healing/i, body, "Steffon's qa-release is the self-healing sweep")
    assert_match(/sweep[^.\n]{0,300}merged: "release"/im, body,
      "the sweep stamps the merged git-location (the crash-recovery signal)")
    assert_match(/supervisor/i, body, "Avi is the review SUPERVISOR")
    assert_match(/spawns?[^.\n]{0,120}parallel/im, body,
      "Avi spawns the primary and light IN PARALLEL (not primary-spawns-light)")
    refute_match(/spawns?\s+the\s+light/i, body,
      "the primary must NOT spawn the light — Avi spawns both in parallel (siblings)")
    refute_match(/nested chain/i, body, "review is no longer a nested chain — siblings under Avi")
    # The old primary-owns-merge framing must be gone (reversed 2026-07-03).
    refute_match(/primary[^.\n]{0,120}runs bin\/release merge/im, body,
      "the PRIMARY no longer runs the merge — review is review-only; Steffon sweeps")
    refute_match(/release conductor then merges each approved PR/i, body,
      "the overview must not regress to the pre-2026-07-02 conductor-merge framing either")
  end

  # Cross-doc tripwire: review and merge are SEPARATE hands — the PRIMARY
  # reviews (review-only), Steffon's sweep merges. Nobody "reviews + merges" in
  # one breath. Catches the "conductor reviews, merges, and deploys" / "Avi
  # reviews and merges" / "primary reviews and merges" framings (incl. the §1.4
  # cold-start block) that the per-file phrase checks above missed. Includes the
  # adapter SOURCES (index.md → /Users/alex/projects/AGENTS.md, claude.md →
  # projects-root CLAUDE.md) so a regression to pre-sweep phrasing in the
  # generated entry docs fails the suite too, and system/mission.md (rewritten
  # in PR #367 with no positive pin of its own) so its framing can't drift back.
  REVIEW_DOCS = %w[
    index.md
    claude.md
    agents/avi/role.md
    system/devops-cycle-design.md
    system/mission.md
    modules/heartbeats.md
    modules/parallel-agent-devops.md
  ].freeze

  test "[static] no review doc says any ONE hand reviews + merges a freshly-reviewed task" do
    REVIEW_DOCS.each do |rel|
      body = norm(rel)
      refute_match(/conductor reviews\b/i, body,
        "#{rel}: the conductor never reviews — Avi thin-delegates, the PRIMARY reviews")
      refute_match(/reviews,?\s+(and\s+)?merges/i, body,
        "#{rel}: drop 'reviews, merges' — review (PRIMARY) and merge (Steffon's sweep) are separate hands")
      refute_match(/primary[^.\n]{0,120}runs bin\/release merge/im, body,
        "#{rel}: the PRIMARY no longer merges — review-only since 2026-07-03; the sweep owns it")
    end
  end

  test "[static] generated agent entrypoint defines the SOP invocation standard before generic triage" do
    body = norm("index.md")
    standard = body.index("SOP Invocation Standard")
    first_rules = body.index("First Rules")
    assert standard, "index.md must expose the SOP invocation standard near the top"
    assert first_rules, "index.md must keep First Rules after the SOP standard"
    assert_operator standard, :<, first_rules,
      "SOP names must resolve before the broader operating rules can send agents into generic triage"
    assert_match(/SOPs are first-class registered commands in this workspace/i, body)
    assert_match(/The set is finite, the names are stable, and every SOP name maps to a repo file/i, body)
    assert_match(/Do not treat an SOP name as ordinary prose, generic GitHub triage, or a broad workflow request/i, body)
    assert_match(/McRitchie operating procedures are normal repo docs, not installed skills/i, body)
    assert_match(/Agent-specific SOPs live at mcritchie-studio\/docs\/agents\/agents\/<agent>\/sops\/<sop>\.md/i, body)
    assert_match(/pr-review \| Avi \| mcritchie-studio\/docs\/agents\/agents\/avi\/sops\/pr-review\.md/i, body)
    assert_match(/read the mapped HEARTBEAT\.md or SOP file before queue inspection, --help probing, GitHub PR discovery, or tool\/plugin selection/i, body)
  end

  test "[static] claude adapter also points SOP invocations to AGENTS standard first" do
    body = norm("claude.md")
    standard = body.index("SOP invocation standard")
    devops_gate = body.index("STOP — before writing ANY code")
    assert standard, "Claude adapter must expose SOP routing before the DevOps gate"
    assert devops_gate, "Claude adapter must keep the DevOps gate"
    assert_operator standard, :<, devops_gate,
      "SOP prompts must be resolved before generic workflow handling"
    assert_match(/McRitchie SOPs live in \/Users\/alex\/projects\/AGENTS\.md's SOP Invocation Standard/i, body)
    assert_match(/SOPs are first-class registered commands with finite names and stable files/i, body)
    assert_match(/pr-review means read mcritchie-studio\/docs\/agents\/agents\/avi\/sops\/pr-review\.md first/i, body)
    assert_match(/do not start with bin\/pr-review --help, bin\/qa-intake, or GitHub PR discovery/i, body)
  end

  test "[static] markdown launch docs describe the parallel primary+light siblings under the supervisor, review-only" do
    body = norm("modules/parallel-agent-devops.md")
    assert_match(/supervisor/i, body, "Avi is the review SUPERVISOR")
    assert_match(/parallel/i, body, "the two experts are spawned in parallel as siblings")
    refute_match(/nested cascade/i, body, "review is no longer a nested cascade")
    refute_match(/spawns?\s+the\s+light/i, body,
      "the primary must NOT spawn the light — Avi spawns both in parallel")
    assert_match(/review-only/i, body, "the launch docs state the review-only contract")

    body = norm("agents/steffon/sops/qa-release.md")
    assert_match(/self-healing/i, body, "…and hands the merge to Steffon's self-healing sweep")

    Dir.glob(AGENTS.join("agents", "*", "sops", "*.md")).each do |path|
      refute_match(/atomic-event heartbeat/i, File.read(path),
        "#{path}: act SOPs must stay independent of heartbeat attribution")
    end
  end

  test "[static] the SOP vocabulary hands the merge to Steffon's sweep (no divergence notes)" do
    steps = Devops::Vocabulary.lanes.flat_map { |lane| lane[:steps] }
    assert(steps.none? { |step| step[:diverges].present? },
      "no SOP step should carry a :diverges note — the model matches the SOP")
    release_branch = steps.find { |step| step[:label] == "Release Branch" }
    assert_not_nil release_branch
    assert_match(/sweep/i, release_branch[:expectation], "the merge step is the self-healing sweep's")
    assert_match(/bin\/release (prepare|merge)/i, release_branch[:expectation])
    refute_match(/primary/i, release_branch[:expectation],
      "the merge no longer belongs to the PRIMARY reviewer — review is review-only")
  end

  # harden-review-lane-roles: the supervisor spawns BOTH reviewers as its own
  # parallel children, announced by two intent-labeled delegate actions — the
  # primary never spawns the light. Both the interactive SOP and the shared
  # primitive must name the two labels so the interactive Agent-tool path can't
  # drift back to "Avi spawns only the primary; the primary spawns the light".
  test "[integration] the pr-review SOP and primitive name the two intent-labeled delegate actions" do
    [
      "agents/avi/sops/pr-review.md",
      "modules/pr-review-sop.md"
    ].each do |rel|
      body = norm(rel)
      assert_match(/summon primary review/i, body,
        "#{rel}: the primary spawn is an intent-labeled delegate action")
      assert_match(/summon light review/i, body,
        "#{rel}: the light spawn is an intent-labeled delegate action")
      assert_match(/parallel/i, body, "#{rel}: both reviewers spawn in parallel")
      refute_match(/spawns?\s+the\s+light/i, body,
        "#{rel}: the primary must NOT spawn the light — the supervisor spawns both")
    end
  end

  # harden-review-lane-roles: the role SOPs sharpen the split — PRIMARY owns the
  # gates + drives the verdict, LIGHT is a focused second read that does neither.
  test "[integration] the primary and light role SOPs sharpen the gate/verdict ownership split" do
    primary = norm("agents/avi/sops/pr-review-primary.md")
    assert_match(/review OWNER/i, primary, "the PRIMARY is the review owner")
    assert_match(/own the gates/i, primary, "the PRIMARY owns the gates")
    assert_match(/DRIVE the verdict/i, primary, "the PRIMARY drives the verdict")

    light = norm("agents/avi/sops/pr-review-light.md")
    assert_match(/focused second read/i, light, "the LIGHT is a focused second read")
    assert_match(/do not run the gates/i, light, "the LIGHT does not run the gates")
    assert_match(/do not drive the verdict/i, light, "the LIGHT does not drive the verdict")
    # The light must not claim the primary's ownership.
    refute_match(/you own the gates/i, light,
      "the LIGHT never owns the gates — that is the primary's")
  end

  # harden-review-lane-roles: each reviewer soul carries a per-domain REVIEW
  # CHECKLIST of hard-won gotchas in its own role.md (domain = soul + checklist).
  REVIEWER_CHECKLISTS = {
    "agents/carl/role.md" => /N\+1/i,
    "agents/shannon/role.md" => /space-separated/i,
    "agents/jasper/role.md" => /EXPECTED_IDL_HASH/i,
    "agents/steffon/role.md" => /SKIP_IDL_VERIFICATION/i,
    "agents/alex/role.md" => /install-agent-docs/i
  }.freeze

  test "[integration] each reviewer soul role.md carries a per-domain Review Checklist" do
    REVIEWER_CHECKLISTS.each do |rel, domain_anchor|
      body = norm(rel)
      assert_match(/Review Checklist/i, body, "#{rel}: reviewer soul must carry a Review Checklist")
      assert_match(domain_anchor, body,
        "#{rel}: the checklist must include its domain's hard-won gotcha")
    end
  end
end
