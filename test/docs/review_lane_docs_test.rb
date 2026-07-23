# frozen_string_literal: true

require "test_helper"

# Guard for the review-lane SOP (3-level supervisor hierarchy, 2026-07-06): the
# session Pokémon → Avi the SUPERVISOR (a thin gate that NEVER reviews the code)
# → the domain experts. Avi picks the pair (bin/reviewer-select) and SPAWNS both
# the PRIMARY and LIGHT reviewers IN PARALLEL as sibling children (NOT the old
# "primary spawns the light" nested chain), collects both verdicts, and gates.
# And — under the LIVE accepted ladder — review MERGES the feat PR into `accepted`
# (stamping merged: "accepted") and then STOPS at reviewed: review never touches
# release/main and never deploys. Steffon's self-healing qa-release sweep promotes
# ONE accepted→release batch PR per repo (not N per-task merges), re-stamps
# merged: "release", and flips members assembled on QA-green. These assertions are
# deliberate tripwires: revert the model and they fail.
class ReviewLaneDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read: drop * and ` so bold/italic/code emphasis
  # can't break a phrase match, and collapse whitespace so a line-wrapped sentence
  # still matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] carl role.md frames Carl as the standing primary review OWNER — no Avi supervisor" do
    body = norm("agents/carl/role.md")
    assert_match(/standing primary/i, body, "Carl is the standing primary reviewer")
    assert_match(/owner of PR review|PR Review Ownership|review owner/i, body, "Carl owns PR review")
    assert_match(/no Avi supervisor/i, body, "the model has no Avi supervisor layer")
    assert_match(/one Carl per PR/i, body, "the review session spins one Carl per PR")
    assert_match(/light/i, body, "Carl summons a domain light specialist at his discretion")
    assert_match(/merges? approved work into[^.\n]{0,20}accepted/i, body, "Carl merges approved work into accepted")
    refute_match(/\bheavy\b/i, body, "the heavy→primary rename must not regress in the docs")
  end

  test "[static] avi role.md no longer claims the review supervisor role" do
    body = norm("agents/avi/role.md")
    refute_match(/review supervisor|SUPERVISOR/i, body, "Avi is no longer the review supervisor — Carl owns review")
    assert_match(/qa-release/i, body, "Avi owns the qa-release assembly + QA step")
  end

  test "[static] the devops-cycle runbook has review merge to accepted and the sweep promote ONE accepted→release batch PR" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/merges? the feat(ure)? PR into accepted/i, body,
      "review merges the feat PR into accepted — the accepted-ladder authority")
    assert_match(/merged: "accepted"/i, body,
      "review stamps the accepted git-location (merged: accepted) on merge")
    assert_match(/one accepted → release batch PR/i, body,
      "the sweep promotes ONE accepted→release batch PR per repo — not N per-task merges")
    assert_match(/self-healing/i, body, "the qa-release is the self-healing sweep")
    assert_match(/sweep[^.\n]{0,300}merged: "release"/im, body,
      "the sweep re-stamps the merged git-location (the crash-recovery signal)")
    # Review is Carl-owned — one Carl per PR, no Avi supervisor (re-homed 2026-07-22).
    assert_match(/one Carl per PR/i, body, "review is one Carl per PR")
    assert_match(/no Avi supervisor|not a supervisor/i, body, "there is no Avi supervisor")
    # The old primary-owns-release-merge framing must be gone — review merges only to accepted.
    refute_match(/primary[^.\n]{0,120}runs bin\/release merge/im, body,
      "review is review-only for release — it merges to accepted; the sweep promotes accepted→release")
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
        "#{rel}: drop 'reviews, merges' — review (Carl) merges to accepted; the accepted→release merge (Avi's sweep) is a separate hand")
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
    assert_match(/pr-review \| Carl \| mcritchie-studio\/docs\/agents\/agents\/carl\/sops\/pr-review\.md/i, body)
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
    assert_match(/pr-review means read mcritchie-studio\/docs\/agents\/agents\/carl\/sops\/pr-review\.md first/i, body)
    assert_match(/do not start with bin\/pr-review --help, bin\/qa-intake, or GitHub PR discovery/i, body)
  end

  test "[static] markdown launch docs describe one Carl per PR (no Avi supervisor), review-only, merge to accepted" do
    body = norm("modules/parallel-agent-devops.md")
    assert_match(/one Carl per PR/i, body, "review is one Carl per PR — the standing primary + owner")
    assert_match(/no Avi supervisor|not a supervisor/i, body, "there is no Avi supervisor")
    assert_match(/parallel/i, body, "many pr-review sessions run in parallel on independent tasks")
    assert_match(/merges? the feat(ure)? PR into accepted/i, body,
      "the launch docs state review merges the feat PR into accepted")
    assert_match(/one accepted → release batch PR/i, body,
      "the launch docs state the sweep promotes ONE accepted→release batch PR per repo")

    body = norm("agents/avi/sops/qa-release.md")
    assert_match(/self-healing/i, body, "…and hands the accepted→release promotion to Avi's self-healing sweep")

    Dir.glob(AGENTS.join("agents", "*", "sops", "*.md")).each do |path|
      refute_match(/atomic-event heartbeat/i, File.read(path),
        "#{path}: act SOPs must stay independent of heartbeat attribution")
    end
  end

  test "[static] the SOP vocabulary hands the merge to the self-healing sweep (no divergence notes)" do
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

  # reslot-souls-heartbeats: the review session spins ONE Carl per PR (the standing
  # primary + owner — no Avi supervisor), and Carl summons ONE domain light at his
  # discretion (his own child), labeled `light review: <soul>`. Both the SOP and the
  # shared primitive must frame the Carl-owned model so neither drifts back to the
  # retired "Avi supervisor spawns both in parallel" framing.
  test "[integration] the pr-review SOP and primitive frame the Carl-owned model (one Carl per PR, a light at his discretion)" do
    [
      "agents/carl/sops/pr-review.md",
      "modules/pr-review-sop.md"
    ].each do |rel|
      body = norm(rel)
      assert_match(/one Carl per PR/i, body,
        "#{rel}: the session spins one Carl per PR — the standing primary + owner")
      assert_match(/no Avi supervisor/i, body,
        "#{rel}: there is no Avi supervisor layer")
      assert_match(/light/i, body,
        "#{rel}: Carl summons a domain light specialist at his discretion")
      refute_match(/summon primary review/i, body,
        "#{rel}: there is no separate primary spawn — the session spins one Carl")
    end
  end

  # harden-review-lane-roles: the role SOPs sharpen the split — PRIMARY owns the
  # gates + drives the verdict, LIGHT is a focused second read that does neither.
  test "[integration] the primary and light role SOPs sharpen the gate/verdict ownership split" do
    primary = norm("agents/carl/sops/pr-review-primary.md")
    assert_match(/review OWNER/i, primary, "the PRIMARY is the review owner")
    assert_match(/own the gates/i, primary, "the PRIMARY owns the gates")
    assert_match(/DRIVE the verdict/i, primary, "the PRIMARY drives the verdict")

    light = norm("agents/carl/sops/pr-review-light.md")
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
