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
  # THE COLLIDING PAIR, and it is not hypothetical: studio-engine #245 is the PR
  # this whole guard was built for, and #24 is a real neighbour in the same repo.
  # One url is a strict PREFIX of the other, which is the entire defect.
  ENGINE_24 = "https://github.com/McRitchie-Studio/studio-engine/pull/24"
  AT = "2026-09-02T14:00:00Z"

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

  # THE COMPLETENESS PROPERTY: every grade `decide` can actually produce is either
  # PERMITTED or carries a message the operator can act on. So a grade added later
  # cannot slip through as a silent refusal with nothing behind it.
  #
  # WHAT THIS TEST USED TO BE, and why it proved nothing: it derived the grade list
  # from the real predicate — correctly — and then built its assertion from a
  # hardcoded `prs: [pr(:open)]`, never passing `grade` into anything. So every
  # unpermitted grade rendered the same open-PR refusal, which is of course
  # non-empty, and the property was never exercised. Proven inert by execution: an
  # unpermitted grade with no message left the file at 26 runs / 0 failures.
  #
  # It bites now because the message is looked up BY GRADE, through the same
  # dispatcher bin/task calls, using the very roster and stage that produced it.
  # An unanswered grade returns nil, and nil is a fact this can see.
  def test_every_grade_decide_produces_is_either_permitted_or_explained
    cases = ROSTERS.product(STAGES).map do |prs, stage|
      [OpenPrGuard.decide(prs: prs, stage: stage), prs, stage]
    end

    grades = cases.map(&:first).uniq
    refute_empty grades
    assert_includes grades, :open,
                    "the rosters must actually reach the refusing grade, or this property " \
                    "passes by never testing anything"

    cases.each do |grade, prs, stage|
      next if OpenPrGuard.permitted?(grade)

      message = OpenPrGuard.message_for(grade: grade, slug: "probe", stage: stage, prs: prs)
      refute_nil message, "grade #{grade.inspect} refuses with no message to act on"
      refute_empty message.to_s.strip, "grade #{grade.inspect} refuses with an empty message"
    end
  end

  # The other half of the same property, and the half a bare `permitted?` check
  # hides: :unreadable PROCEEDS and still has something to say. Permission and
  # silence are different questions.
  def test_a_permitted_grade_can_still_carry_a_message
    message = OpenPrGuard.message_for(grade: :unreadable, slug: "probe", stage: "designed",
                                      prs: [pr(:unknown)])

    assert OpenPrGuard.permitted?(:unreadable)
    assert_includes message.to_s, "could not read"
  end

  def test_message_for_routes_open_to_the_refusal
    message = OpenPrGuard.message_for(grade: :open, slug: "probe", stage: "shipped",
                                      prs: [pr(:open)])

    assert_includes message.to_s, "REFUSING to archive probe"
    assert_includes message.to_s, "shipped", "the stage it was in is part of the refusal"
  end

  # A grade with genuinely nothing to say says nothing — the dispatcher must not
  # manufacture a message for a clean archive.
  def test_message_for_is_silent_on_a_clean_grade
    %i[concluded none clear].each do |grade|
      assert_nil OpenPrGuard.message_for(grade: grade, slug: "probe", stage: "designed",
                                         prs: [pr(:merged)]),
                 "#{grade.inspect} archives cleanly; a message here would be noise"
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

  # ── reading the receipt back: WHOLE URLS, NOT PREFIXES ──────────────────────

  # THE UNSAFE FAILURE, and the reason this task exists. `.../pull/24` is a strict
  # PREFIX of `.../pull/245`, so the substring reader this replaced
  # (`recorded.any? { |entry| entry.include?(ref[:url]) }`) answered TRUE for a PR
  # nobody ever abandoned. Downstream, `bin/task orphan-prs` printed a REAL orphan
  # as "abandoned on purpose", suppressed its `decide:` remediation line, and sorted
  # it to the bottom — the alarm going quiet about live, forgotten work, which is
  # precisely the harm this guard shipped to close.
  #
  # THE SECOND ASSERTION IS THE CONTROL. It proves the fixture still exhibits the
  # collision, so a green first assertion can never mean "these two urls simply do
  # not overlap" — the way a fixture that cannot express the bug passes against the
  # defect and the fix alike.
  def test_a_receipt_for_245_does_not_cover_24
    receipt = OpenPrGuard.record(prs: [pr(:open, url: ENGINE)], at: AT)

    refute OpenPrGuard.abandonment_recorded?(receipt, ENGINE_24),
           "#{ENGINE_24} was never abandoned; reading it as deliberate silences the alarm " \
           "about a real orphan"
    assert receipt.first.include?(ENGINE_24),
           "control: the receipt really does CONTAIN the shorter url, so the refutation above " \
           "is testing the anchoring and not an accident of these two strings"
  end

  def test_a_receipt_for_245_still_covers_245
    receipt = OpenPrGuard.record(prs: [pr(:open, url: ENGINE)], at: AT)

    assert OpenPrGuard.abandonment_recorded?(receipt, ENGINE),
           "anchoring must not cost the receipt its actual job"
  end

  # The other direction, which the substring reader got right by accident: a
  # receipt for the SHORTER url must not cover the longer one either.
  def test_a_receipt_for_24_does_not_cover_245
    receipt = OpenPrGuard.record(prs: [pr(:open, url: ENGINE_24, number: "24")], at: AT)

    refute OpenPrGuard.abandonment_recorded?(receipt, ENGINE)
  end

  def test_a_receipt_written_by_hand_as_a_bare_url_still_matches
    assert OpenPrGuard.abandonment_recorded?([ENGINE], ENGINE),
           "a bare url is its own first field; a human-written receipt must still count"
  end

  def test_an_empty_or_missing_receipt_covers_nothing
    refute OpenPrGuard.abandonment_recorded?(nil, ENGINE)
    refute OpenPrGuard.abandonment_recorded?([], ENGINE)
    refute OpenPrGuard.abandonment_recorded?([ENGINE], "  "),
           "an empty url must never match a receipt; every PR would read as abandoned"
  end

  # ── the receipt covers every PR the override drops ──────────────────────────

  # THE MIRROR OF THE PREFIX BUG, erring SAFE and still wrong. `record` folded
  # `open_prs`, so on a roster of [OPEN, UNREADABLE] the refusal named both PRs,
  # one `--force` abandoned both, and only one receipt was written. The unreadable
  # sibling then reported as ORPHANED — forgotten — when it was dropped by the same
  # deliberate keystroke. Measured 2026-09-02: 2 PRs in, 1 receipt out.
  def test_force_records_a_receipt_for_the_unreadable_sibling_too
    entries = OpenPrGuard.record(
      prs: [pr(:open, url: ENGINE), pr(:unknown, url: SOLANA, repo: "McRitchie-Studio/solana-studio",
                                       number: "9")],
      at: AT
    )

    assert_equal 2, entries.size, "both PRs were dropped by the same choice: #{entries.inspect}"
    assert OpenPrGuard.abandonment_recorded?(entries, SOLANA),
           "the PR whose state we could not read is the one most likely to be forgotten"
  end

  # The receipt is prose a human reads months later. `:unknown` there invites the
  # reader to ask "unknown what?" about the one field telling them the check never
  # completed; every other message in the guard calls that state unreadable.
  def test_the_receipt_calls_an_unread_state_unreadable
    entry = OpenPrGuard.record(prs: [pr(:unknown), pr(:open, url: SOLANA)], at: AT).first

    assert_includes entry, "unreadable"
    refute_includes entry, "unknown"
  end

  def test_a_resolved_pr_never_gets_a_receipt
    entries = OpenPrGuard.record(prs: [pr(:merged), pr(:closed), pr(:open, url: SOLANA)], at: AT)

    assert_equal 1, entries.size, "merged and closed PRs were resolved, not abandoned"
    assert_includes entries.first, SOLANA
  end

  def test_the_receipt_records_the_soul_who_made_the_choice
    entry = OpenPrGuard.record(prs: [pr(:open)], at: AT, by: "carl").first

    assert_includes entry, "by carl",
                    "a later reader needs WHO decided, not only that somebody did"
  end

  private

  # Every roster shape the gate can be handed, used by the completeness property.
  # Kept beside `pr` so a new state added to the vocabulary has one obvious home.
  ROSTERS = [
    [],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :open }],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :merged }],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :closed }],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :unknown }],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :open },
     { repo: "r/b", number: "2", url: "https://github.com/r/b/pull/2", state: :unknown }],
    [{ repo: "r/a", number: "1", url: "https://github.com/r/a/pull/1", state: :merged },
     { repo: "r/b", number: "2", url: "https://github.com/r/b/pull/2", state: :unknown }]
  ].freeze

  STAGES = %w[designed building submitted reviewed assembled shipped archived blocked].freeze

  def pr(state, url: ENGINE, repo: "McRitchie-Studio/studio-engine", number: "245")
    { repo: repo, number: number, url: url, state: state }
  end
end
