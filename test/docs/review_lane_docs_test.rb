# frozen_string_literal: true

require "test_helper"
require_relative "../support/stated_prose"

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
  def normalize(text)
    text.gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  def norm(rel)
    normalize(File.read(AGENTS.join(rel)))
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

  # ── document-reviewer-select-claim ────────────────────────────────────────
  #
  # PR #1521 (merged 93e74215) made `bin/reviewer-select` ACQUIRE the per-task
  # review claim BEFORE recording intent, and recording is the DEFAULT. So a bare
  # run that a doc presents as a "preview" now takes a ~3h25m lease
  # (ClaimLease::REVIEW_TTL_SECONDS = 12_275) with NO renewer behind it — selection
  # only reserves the seconds until the primary's own acquire. A live
  # `task_review_claims` row drops the task out of `Task.reviewable`
  # (the `Task.reviewable` scope in app/models/task.rb excludes any submitted task
  # carrying an unexpired claim) and therefore out of `bin/task claim-next-review` for the whole
  # TTL. The lapse is the recoverable direction and was chosen deliberately, but a
  # reader following our own docs should not trip it at all.

  # EVERY source this repo states something in, walked — not a fixed list, and NOT
  # `docs/agents/**` any more. "Every preview invocation" is a universal claim, and
  # this glob could not honour it: the most authoritative preview instruction in the
  # tree was the one in the FEATURE'S OWN SERVICE, app/services/reviewer_selector.rb,
  # sitting outside `docs/` where nothing looked. The shared population (markdown
  # anywhere plus the comment bodies of config/app/lib/bin) is the same one the
  # turf-vault lane guard reads — decided once, in test/support/stated_prose.rb, so
  # the two guards cannot grow two exemption conventions.
  def guarded_sources
    StatedProse.sources(Rails.root)
  end

  # Sentence-grained, because the check has to tell an INSTRUCTION ("previewing with
  # `bin/reviewer-select <task>`") from a STATEMENT ABOUT the default ("…but
  # `bin/reviewer-select <task>` records by default"). Splitting on a period followed
  # by whitespace leaves `Task.reviewable` and `TaskEvent.metadata` intact.
  def sentences(text)
    normalize(text).split(/(?<=\.)\s+/)
  end

  # The invocation, plus the run of flags trailing it. Matching the FLAG RUN rather
  # than the character right after the placeholder is what makes the opt-out
  # order-insensitive.
  #
  # THE OLD FORM WAS `<task[^>]*>(?!\s*--(?:no-record|dry))`, a lookahead at the
  # position immediately after the placeholder — so `bin/reviewer-select <task>
  # --json --no-record` read as BARE. That is a safe, fully opted-out invocation, and
  # reddening it is the failure mode this guard can least afford: a guard that cries
  # wolf on correct text teaches authors to route around it. The run stops at the
  # first non-flag word, so a `--no-record` mentioned later in the sentence as prose
  # still cannot launder a bare command.
  SELECT_INVOCATION = %r{bin/reviewer-select\s+<task[^>]*>((?:\s+\[?--[a-z][\w-]*\]?(?:[ =](?!--)[\w,./-]+)?)*)}
  OPTED_OUT = /--(?:no-record|dry)\b/

  # A sentence carrying at least one invocation whose own flag run opts out of nothing.
  def bare_preview?(sentence)
    return false unless sentence.match?(/preview/i)
    return false if sentence.match?(STATES_RECORDING_DEFAULT)

    sentence.to_enum(:scan, SELECT_INVOCATION).any? { !Regexp.last_match[1].match?(OPTED_OUT) }
  end
  # The ONE sentence shape allowed to carry a bare invocation: one whose subject IS
  # the recording default (parallel-agent-devops.md's "records by default" paragraph,
  # which exists precisely to teach this). Measured, not assumed — as of 2026-09-22
  # exactly two active sentences match it, and both are about the behaviour rather
  # than about running a preview. Deliberately NOT named as a remedy in the failure
  # message: a preview instruction is fixed by adding the flag, never by bolting this
  # phrase onto it.
  STATES_RECORDING_DEFAULT = /records? by default|recording is the DEFAULT/i

  test "[static] every active source shows --no-record on a PREVIEW invocation of bin/reviewer-select" do
    offenders = guarded_sources.flat_map do |path|
      rel = StatedProse.rel(Rails.root, path)
      sentences(StatedProse.prose(path)).filter_map do |sentence|
        next unless bare_preview?(sentence)

        "#{rel}: #{sentence.strip[0, 150]}"
      end
    end

    assert_empty offenders,
      "Preview invocations must be written `bin/reviewer-select <task> --no-record`. " \
      "This reads COMMENTS as well as markdown: the site that started this guard's " \
      "second round was app/services/reviewer_selector.rb — the feature's own " \
      "service, which no docs glob could ever reach. " \
      "Recording is the DEFAULT, and recording first ACQUIRES the task's review claim — " \
      "a ~3h25m lease (ClaimLease::REVIEW_TTL_SECONDS) with no renewer behind it, which " \
      "drops the task out of Task.reviewable and out of `bin/task claim-next-review` " \
      "until it lapses. Add the flag to the command; do not reword around it:\n  " +
      offenders.join("\n  ")
  end

  test "[static] the pr-review primitive describes the review claim and BOTH arms of exit 10" do
    body = norm("modules/pr-review-sop.md")

    assert_match(/ACQUIRES the review claim/i, body,
      "the shared primitive must say that recording ACQUIRES the per-task review claim")
    assert_match(/REVIEW_TTL_SECONDS/, body,
      "name the lease constant so a reader can size what a bare run costs")
    assert_match(/Task\.reviewable/, body,
      "say what a live claim locks the task out of — Task.reviewable, hence claim-next-review")
    assert_match(/exits? 10/i, body, "exit 10 must be named as the skip it is")

    # BOTH ARMS. They exit on the same code and carry OPPOSITE remedies, and
    # bin/pr-review's own exit-10 message hard-codes the HELD wording only — so a
    # reader who hits the self-review arm is told the wrong thing unless the
    # primitive covers it.
    assert_match(/refuse_held!/, body,
      "the HELD arm: a DIFFERENT live session holds the claim, and it names the holder")
    assert_match(/refuse_self_review!/, body,
      "the SELF-REVIEW arm: the board refused the claim because the primary is an author")
    assert_match(/review-claim release/i, body,
      "the held arm's remedy — ask the holder to release, take the next task")
    assert_match(/move <task> building --actor/i, body,
      "the self-review arm's remedy — reconcile the AUTHOR SET, not take the next task")
  end

  # The review lane's intent must come from the CLAIM. `bin/task intent <task> --to
  # reviewed` POSTs /api/v1/tasks/<slug>/intent and touches `task_review_claims`
  # NOWHERE — the claim-less write that let two sessions select PR #1516 on
  # 2026-09-21, both pairs carl+steffon, one seconds from merging a tree the other
  # had bounced. `bin/task review-claim acquire` is the replacement:
  # TaskReviewClaim.acquire writes the reviewed intent from the claim side
  # (app/models/task_review_claim.rb#record_review_intent), so the crew seat and
  # the reservation land in one atomic write.
  #
  # SCOPED TO `--to reviewed`, and the scope is MEASURED rather than assumed: the
  # DEPLOY lane's `bin/task intent --to assembled` / `--to shipped` fallback is
  # legitimate and stays. `Task.reviewable` is the only stage scope keyed on a claim
  # row; there is no assembled/shipped equivalent, so a deploy-lane intent cannot
  # announce a reservation that does not exist. A guard that banned the subcommand
  # outright would teach that false rule.
  REVIEWED_INTENT = %r{bin/task intent [^.]{0,80}--to reviewed}i
  PROHIBITS = /\bdo not\b|\bnever\b|\bdon't\b/i

  test "[static] no active source routes a reader to the claim-less bin/task intent --to reviewed" do
    offenders = guarded_sources.flat_map do |path|
      rel = StatedProse.rel(Rails.root, path)
      sentences(StatedProse.prose(path)).filter_map do |sentence|
        next unless sentence.match?(REVIEWED_INTENT)
        # Naming it in order to FORBID it is the primitive's job, and passes.
        next if sentence.match?(PROHIBITS)

        "#{rel}: #{sentence.strip[0, 150]}"
      end
    end

    assert_empty offenders,
      "These sentences hand a reader the review-lane intent write with no claim behind it. " \
      "Route them to `bin/task review-claim acquire <task>` instead — TaskReviewClaim.acquire " \
      "writes the reviewed intent from the claim side, so the reservation and the crew seat " \
      "land together. Name `bin/task intent --to reviewed` only to forbid it. (The DEPLOY " \
      "lane's --to assembled / --to shipped fallback is a different case and is not covered " \
      "by this guard.):\n  " + offenders.join("\n  ")
  end

  # ── The preview checker itself bites ──────────────────────────────────────
  #
  # This guard shipped with NO fixtures, which made its live criterion satisfiable by
  # deleting the offending sentence: fix the instance, retire the guard, and nobody
  # can tell the difference from a green run. The first entry is VERBATIM from
  # app/services/reviewer_selector.rb as it stood before this task, so the text
  # keeps biting whatever happens to the live comment.
  BARE_PREVIEWS = {
    "reviewer_selector.rb, verbatim — the service comment no docs glob could see" =>
      "`bin/reviewer-select <task>` is the CLI wrapper a review session runs to preview\n" \
      "the pair + the auditable tiebreak from `.explain`.",
    "a plain preview instruction" =>
      "Preview the pair with `bin/reviewer-select <task-slug>` before you spawn.",
    "opted out of the WRONG thing" =>
      "Preview the pair with `bin/reviewer-select <task> --json`.",
    "a flag run that never reaches an opt-out" =>
      "Preview it: `bin/reviewer-select <task> --json --qa-owner carl`."
  }.freeze

  def test_the_preview_checker_catches_a_bare_invocation
    BARE_PREVIEWS.each do |label, prose|
      assert(sentences(prose).any? { |s| bare_preview?(s) },
             "#{label}: this is the defect the guard exists for and it read as clean")
    end
  end

  # Correct prose must pass, and the second entry is the whole reason the matcher
  # changed: a safe, fully opted-out invocation that the old position-anchored
  # lookahead reddened because `--json` sat between the placeholder and the flag.
  OPTED_OUT_PREVIEWS = {
    "the canonical preview line" =>
      "`bin/reviewer-select <task> --no-record` previews the pair (primary Carl\n" \
      "plus one light).",
    "the flag-ORDER false red the old lookahead produced" =>
      "Preview the pair with `bin/reviewer-select <task> --json --no-record`.",
    "the --dry alias, reached past another flag" =>
      "Preview it with `bin/reviewer-select <task> --qa-owner carl --dry`.",
    "a STATEMENT about the default, not an instruction to run one" =>
      "You may want a preview, but `bin/reviewer-select <task>` records by default —\n" \
      "it writes the pair and takes the claim.",
    "prose that mentions no preview at all" =>
      "`bin/reviewer-select <task>` is how the review session records the pair."
  }.freeze

  def test_the_preview_checker_passes_opted_out_and_descriptive_prose
    OPTED_OUT_PREVIEWS.each do |label, prose|
      refute(sentences(prose).any? { |s| bare_preview?(s) },
             "#{label}: correct prose was flagged — a guard that cries wolf gets muted")
    end
  end
end
