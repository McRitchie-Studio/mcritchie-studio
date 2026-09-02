# frozen_string_literal: true

# Pure unit test for OpenPrGuard — the open-PR archive decision with every fact
# injected. No board, no `gh`, no filesystem.
#
#   ruby -Itest test/lib/open_pr_guard_test.rb
require "minitest/autorun"
require_relative "../../lib/open_pr_guard"

class OpenPrGuardTest < Minitest::Test
  ENGINE = "https://github.com/McRitchie-Studio/studio-engine/pull/245"
  SOLANA = "https://github.com/McRitchie-Studio/solana-studio/pull/9"

  # THE LIVE RECORD, copied from `bin/task show move-web3-modals-to-solana --json`
  # on 2026-09-02. Both keys populated, the singular duplicating one map entry —
  # which is the shape that actually occurs, not a shape invented for the test.
  MEASURED = {
    "pr_url" => ENGINE,
    "pr_urls" => { "solana-studio" => SOLANA, "studio-engine" => ENGINE },
    "repositories" => %w[studio-engine solana-studio]
  }.freeze

  # ── refs: THE WHOLE SET ─────────────────────────────────────────────────────

  def test_refs_reads_the_map_as_well_as_the_singular
    refs = OpenPrGuard.refs(MEASURED)

    assert_equal 2, refs.size, "the map's second repo is a PR too: #{refs.inspect}"
    assert_includes refs.map { |r| r[:url] }, SOLANA,
                    "reading only devops.pr_url is the trap this defect sets"
  end

  # The singular appears in BOTH keys on the live record. It is one PR, and a
  # refusal that named it twice would read as two orphans.
  def test_refs_dedupes_a_pr_named_by_both_keys
    urls = OpenPrGuard.refs(MEASURED).map { |r| r[:url] }

    assert_equal urls.uniq, urls
  end

  # THE INVERSE ORDERING — the one a singular-only check survives, and the reason
  # the fold reads both keys rather than trusting `pr_url` to be representative.
  def test_refs_finds_an_open_pr_reachable_only_through_the_map
    devops = { "pr_url" => SOLANA, "pr_urls" => { "studio-engine" => ENGINE } }

    assert_includes OpenPrGuard.refs(devops).map { |r| r[:url] }, ENGINE
  end

  def test_refs_parses_repo_and_number_for_the_gh_call
    ref = OpenPrGuard.refs("pr_url" => ENGINE).first

    assert_equal "McRitchie-Studio/studio-engine", ref[:repo], "gh takes owner/repo"
    assert_equal "245", ref[:number]
  end

  def test_refs_ignores_values_that_name_no_pr
    devops = { "pr_url" => "", "pr_urls" => { "x" => "https://github.com/o/r/issues/4", "y" => "lol" } }

    assert_empty OpenPrGuard.refs(devops)
  end

  def test_refs_survives_a_record_with_no_pr_keys_at_all
    assert_empty OpenPrGuard.refs({})
    assert_empty OpenPrGuard.refs(nil)
  end

  # A map that arrived as a LIST rather than a repo-keyed hash still has to be read.
  # Task.normalize_devops_map accepts both shapes, so both reach this guard.
  def test_refs_reads_a_list_shaped_map
    assert_equal 1, OpenPrGuard.refs("pr_urls" => [ENGINE]).size
  end

  # ── state_of: AN UNREAD FACT IS NEVER A RESOLVED ONE ────────────────────────

  def test_state_of_maps_the_github_vocabulary
    assert_equal :open,   OpenPrGuard.state_of("OPEN")
    assert_equal :merged, OpenPrGuard.state_of("MERGED")
    assert_equal :closed, OpenPrGuard.state_of("CLOSED")
  end

  # ALLOW-LIST, deliberately. A deny-list reads every value it has not heard of as
  # resolved, and "resolved" is the direction that strands work silently.
  def test_state_of_reads_anything_unrecognised_as_unknown
    ["", nil, "DRAFT", "LOCKED", "merged-ish", "a future GitHub value"].each do |raw|
      assert_equal :unknown, OpenPrGuard.state_of(raw), "#{raw.inspect} must not read as resolved"
    end
  end

  # ── decide ──────────────────────────────────────────────────────────────────

  def test_an_open_pr_refuses
    grade = OpenPrGuard.decide(prs: [pr(:open)], stage: "designed")

    assert_equal :open, grade
    refute OpenPrGuard.permitted?(grade)
  end

  def test_all_merged_is_clear
    assert_equal :clear, OpenPrGuard.decide(prs: [pr(:merged), pr(:merged)], stage: "designed")
  end

  def test_a_closed_pr_is_resolved_too
    assert_equal :clear, OpenPrGuard.decide(prs: [pr(:closed)], stage: "designed")
  end

  def test_no_prs_at_all_is_permitted
    grade = OpenPrGuard.decide(prs: [], stage: "designed")

    assert_equal :none, grade
    assert OpenPrGuard.permitted?(grade),
           "a gate that refused every task nobody opened a PR for would refuse most of the board"
  end

  # AN OPEN PR OUTRANKS AN UNREADABLE ONE. The one fact we DID establish decides;
  # degrading to the warning because a sibling was unreadable would let a known
  # orphan through on the strength of an unrelated failure.
  def test_a_known_open_pr_wins_over_an_unreadable_sibling
    assert_equal :open, OpenPrGuard.decide(prs: [pr(:unknown), pr(:open)], stage: "designed")
  end

  def test_an_unreadable_pr_warns_rather_than_refusing
    grade = OpenPrGuard.decide(prs: [pr(:unknown), pr(:merged)], stage: "designed")

    assert_equal :unreadable, grade
    assert OpenPrGuard.permitted?(grade),
           "the token expires hourly by design; refusing on every unreadable gh would refuse " \
           "most archives on most days, and a gate that refuses everything gets --force'd to death"
  end

  def test_an_already_archived_task_is_idempotent
    assert_equal :concluded, OpenPrGuard.decide(prs: [pr(:open)], stage: "archived")
  end

  # THE DELIBERATE DIFFERENCE FROM ArchiveHolderGuard::CONCLUDED_STAGES, which skips
  # `shipped`. The `merged` stamp is per-TASK while PRs are per-REPO, so a multi-repo
  # task reaches shipped on its primary with a sibling repo's PR still open — the
  # shape most likely to strand, and the one an inherited skip would exempt.
  def test_a_shipped_task_with_an_open_pr_is_still_refused
    assert_equal :open, OpenPrGuard.decide(prs: [pr(:open)], stage: "shipped")
  end

  # THE COMPLETENESS PROPERTY, asserted against the REAL predicate rather than a
  # hardcoded copy of the grade list. Every grade `decide` can actually produce is
  # either permitted or carries a refusal the operator can act on — so a grade added
  # later cannot slip through as a silent pass with no message behind it.
  def test_every_grade_decide_produces_is_either_permitted_or_explained
    grades = [[], [pr(:open)], [pr(:merged)], [pr(:closed)], [pr(:unknown)],
              [pr(:open), pr(:unknown)], [pr(:merged), pr(:unknown)]]
             .product(%w[designed building submitted reviewed assembled shipped archived])
             .map { |prs, stage| OpenPrGuard.decide(prs: prs, stage: stage) }
             .uniq

    refute_empty grades
    grades.each do |grade|
      next if OpenPrGuard.permitted?(grade)

      text = OpenPrGuard.refusal(slug: "probe", stage: "designed", prs: [pr(:open)])
      refute_empty text.to_s.strip, "grade #{grade.inspect} refuses with no message to act on"
    end
  end

  # ── the messages ────────────────────────────────────────────────────────────

  def test_the_refusal_names_every_pr_not_only_the_open_ones
    prs = [pr(:open, url: ENGINE, repo: "McRitchie-Studio/studio-engine", number: "245"),
           pr(:merged, url: SOLANA, repo: "McRitchie-Studio/solana-studio", number: "9")]
    text = OpenPrGuard.refusal(slug: "probe", stage: "designed", prs: prs)

    assert_includes text, "studio-engine#245"
    assert_includes text, ENGINE
    assert_includes text, "solana-studio#9",
                    "close-vs-revive is decided against the whole set — on the real record the " \
                    "MERGED sibling is what proves the open PR's stated blocker is discharged"
  end

  def test_the_refusal_offers_both_ways_out
    text = OpenPrGuard.refusal(slug: "probe", stage: "designed", prs: [pr(:open)])

    assert_includes text, "gh pr close", "resolving it deliberately is usually the right move"
    assert_includes text, "bin/task move probe archived --force", "and --force is the decision seam"
  end

  # THE CONFIDENT LIE THIS MUST NOT INHERIT. When `archive_holder_facts` rescues, its
  # refusal body claims a live session holds the task while the honest reason sits
  # only in the `warning:` line above it. The equivalent mistake here would be a
  # warning that reads as a finding about the PR's state.
  def test_the_unreadable_warning_never_claims_the_pr_is_open
    text = OpenPrGuard.unreadable_warning(slug: "probe", prs: [pr(:unknown)])

    assert_includes text, "could not read", "it must name what it failed to establish"
    refute_includes text, "REFUSING", "it did not refuse"
    refute_match(/\bis OPEN\b/, text, "the check did not complete; it established nothing")
    assert_includes text, "gh-auth-refresh", "and it must name the usual cause and its fix"
    assert_includes text, "orphan-prs", "and where the orphan it let through stays findable"
  end

  # ── the record ──────────────────────────────────────────────────────────────

  def test_the_record_names_only_the_prs_actually_abandoned
    entries = OpenPrGuard.record(prs: [pr(:open, url: ENGINE), pr(:merged, url: SOLANA)],
                                 at: "2026-09-02T14:00:00Z")

    assert_equal 1, entries.size, "a merged PR was not abandoned"
    assert_includes entries.first, ENGINE
    assert_includes entries.first, "2026-09-02T14:00:00Z", "when the choice was made"
  end

  # Task.normalize_devops_list splits every array element on "\n", so an entry
  # carrying one would be torn into two rows — a receipt reading as more
  # abandonments than actually happened.
  def test_record_entries_are_newline_free
    entries = OpenPrGuard.record(prs: [pr(:open)], at: "2026-09-02T14:00:00Z", by: "carl\nx")

    entries.each { |entry| refute_includes entry, "\n" }
  end

  def test_merged_record_appends_rather_than_replacing
    merged = OpenPrGuard.merged_record(["older-entry"], ["new-entry"])

    assert_equal %w[older-entry new-entry], merged,
                 "a task can be archived, revived and archived again; the earlier decision is " \
                 "still why the earlier PR was dropped"
  end

  def test_merged_record_dedupes_and_drops_blanks
    assert_equal %w[a b], OpenPrGuard.merged_record(["a", "", " b "], ["a"])
  end

  def test_merged_record_tolerates_no_prior_value
    assert_equal ["x"], OpenPrGuard.merged_record(nil, ["x"])
  end

  private

  def pr(state, url: ENGINE, repo: "McRitchie-Studio/studio-engine", number: "245")
    { repo: repo, number: number, url: url, state: state }
  end
end
