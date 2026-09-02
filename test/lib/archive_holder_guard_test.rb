# frozen_string_literal: true

# Unit tests for the archive holder gate's decision table (lib/archive_holder_guard.rb).
# Pure functions — every fact is injected, so nothing here reads a board, a clock, or
# a filesystem. The gate's behaviour as an actual refusal (exit 1, and NO board write)
# is pinned one tier up in test/commands/task_archive_gate_test.rb.
#
#   ruby -Itest test/lib/archive_holder_guard_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../lib/archive_holder_guard"

class ArchiveHolderGuardTest < Minitest::Test
  SESSION = "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b"

  # THE NEAR-MISS'S RECORD, 2026-09-01, as it actually stood: an app and a mascot,
  # and nothing that names a session. This is the fixture the whole file turns on.
  NEAR_MISS = {
    "repositories" => ["mcritchie-studio"],
    "mascot" => "omanyte",
    "mascot_emoji" => "🗿💧",
    "app_color" => "#B57EDC"
  }.freeze

  # ── ACCEPTANCE 1: ARCHIVE REFUSES WHEN THE HOLDER CANNOT BE IDENTIFIED ───────

  def test_the_near_miss_record_is_graded_unverifiable
    grade = decide(stage: "building", devops: NEAR_MISS)

    assert_equal :unverifiable, grade,
                 "a record carrying only an app and a mascot names no session to ask, " \
                 "so the holder CANNOT be identified"
  end

  def test_an_unverifiable_holder_is_not_permitted_to_archive
    refute ArchiveHolderGuard.permitted?(:unverifiable),
           "this is the whole point: `archived` is terminal and the work it destroys is " \
           "uncommitted, so a holder we cannot identify must stop the archive"
  end

  # THE LOAD-BEARING DISTINCTION. :unverifiable and :unheld look identical from the
  # archiving side — neither names a session — and collapsing them is precisely the
  # bug. A mascot is a session's paint: "somebody was here and we cannot tell who" is
  # the opposite fact from "nobody was ever here". Delete PAINT_KEYS and the first
  # test below goes green as :unheld while this one keeps passing, so both are needed.
  def test_a_record_with_no_holder_signal_at_all_archives
    grade = decide(stage: "designed", devops: { "repositories" => ["mcritchie-studio"] })

    assert_equal :unheld, grade,
                 "no session, no mascot, no claim — nobody ever picked it up, and a gate " \
                 "that refused this would refuse every legitimate archive on the board"
    assert ArchiveHolderGuard.permitted?(grade)
  end

  def test_the_same_record_with_a_session_is_checkable_rather_than_unverifiable
    checkable = NEAR_MISS.merge("session_id" => SESSION)

    refute_equal :unverifiable, decide(stage: "building", devops: checkable, abandoned: true),
                 "adding the ONE missing field turns the near-miss record into one we can " \
                 "go and check — that field's absence is the entire defect"
  end

  # Each identity key alone must be enough to make a record checkable. A gate that
  # recognised only `claimed_session` would grade a bound-but-unclaimed task
  # unverifiable and refuse a great many honest archives.
  def test_every_identity_key_makes_a_record_checkable
    ArchiveHolderGuard::IDENTITY_KEYS.each do |key|
      grade = decide(stage: "building", devops: NEAR_MISS.merge(key => SESSION), abandoned: true)

      assert_equal :abandoned, grade,
                   "#{key} names a session, so the holder is identifiable through it"
    end
  end

  # And each paint key alone must trip the refusal. `built_by` is a LIST, which is
  # why `present?` has an Array branch — a naive `.to_s.empty?` reads `[]` as present
  # and would refuse every archive.
  def test_every_paint_key_alone_is_unverifiable
    ArchiveHolderGuard::PAINT_KEYS.each do |key|
      value = key == "built_by" ? ["carl"] : "omanyte"
      grade = decide(stage: "building", devops: { key => value })

      assert_equal :unverifiable, grade, "#{key} shows somebody was here while naming no session"
    end
  end

  def test_an_empty_builder_list_is_not_a_holder_signal
    grade = decide(stage: "designed", devops: { "built_by" => [], "builders" => [] })

    assert_equal :unheld, grade,
                 "an empty list is an absent value, not a holder — reading `[]` as present " \
                 "would refuse every archive of an unclaimed task"
  end

  # ── ACCEPTANCE 2: THE REFUSAL NAMES WHAT IT COULD NOT VERIFY ─────────────────

  def test_the_refusal_names_the_paint_the_record_does_carry
    message = refusal(:unverifiable, stage: "building", devops: NEAR_MISS)

    assert_includes message, "omanyte",
                     "the operator's next move is to go and FIND that session, and the mascot " \
                     "is the only handle the record gives them"
  end

  def test_the_refusal_names_the_identity_it_could_not_find
    message = refusal(:unverifiable, stage: "building", devops: NEAR_MISS)

    ArchiveHolderGuard::IDENTITY_KEYS.each do |key|
      assert_includes message, key,
                       "a refusal must say WHICH fact was missing, or the reader cannot tell " \
                       "what would satisfy it"
    end
  end

  def test_the_refusal_names_the_task_and_its_stage
    message = refusal(:unverifiable, stage: "building", devops: NEAR_MISS)

    assert_includes message, "probe-task", "the refusal must name the task it refused"
    assert_includes message, "building", "and the stage it is in"
  end

  def test_the_refusal_offers_a_way_forward
    message = refusal(:unverifiable, stage: "building", devops: NEAR_MISS)

    assert_includes message, "bin/agent-presence",
                     "the reader must be told HOW to identify the holder, not merely that they must"
    assert_includes message, "--force",
                     "a refusal with no override is a dead end; the human decision seam must be pasteable"
  end

  # A record with NO paint at all can still reach the unverifiable renderer through
  # `refusal`, and it must not print an empty bullet list where an explanation belongs.
  def test_the_refusal_degrades_honestly_with_nothing_to_name
    message = ArchiveHolderGuard.unverifiable_refusal("probe-task", "building", {})

    assert_includes message, "no holder signal we can resolve at all",
                     "with nothing to name it must SAY so, not print a blank"
  end

  # ── THE REST OF THE TABLE ───────────────────────────────────────────────────

  def test_a_live_claim_refuses_and_names_the_session
    grade = decide(stage: "building", devops: { "session_id" => SESSION }, claim_live: true)

    assert_equal :held, grade
    refute ArchiveHolderGuard.permitted?(grade)

    message = ArchiveHolderGuard.held_refusal("probe-task", {
                                                "claimed_session" => SESSION,
                                                "claim_nonce" => "holder01",
                                                "claim_expires_at" => (Time.now + 90).utc.iso8601
                                              })
    assert_includes message, SESSION[-4..], "the refusal must name WHO holds it"
    assert_includes message, "last heartbeat", "and how fresh that holder's liveness signal is"
  end

  def test_a_corrupt_lease_reports_that_it_could_not_be_checked
    message = ArchiveHolderGuard.held_refusal("probe-task", {
                                                "claimed_session" => SESSION,
                                                "claim_expires_at" => "not-a-time"
                                              })

    assert_includes message, "UNPARSEABLE",
                     "an unreadable expiry is an unknown, and the refusal must say that rather " \
                     "than print a confident heartbeat age it does not have"
  end

  def test_an_identified_but_still_working_holder_refuses
    grade = decide(stage: "submitted", devops: { "session_id" => SESSION }, abandoned: false)

    assert_equal :working, grade
    refute ArchiveHolderGuard.permitted?(grade)
  end

  def test_an_identified_and_provably_abandoned_holder_archives
    grade = decide(stage: "submitted", devops: { "session_id" => SESSION }, abandoned: true)

    assert_equal :abandoned, grade
    assert ArchiveHolderGuard.permitted?(grade),
           "a session we CAN check, checked, and found gone is exactly what the gate is " \
           "supposed to let through"
  end

  # Reaching `shipped` means the code is merged to `main`, so there is no unmerged
  # work left for an archive to destroy. This is the lane `bin/release archive`
  # sweeps, and a gate that blocked it would wedge the DevOps loop's conclusion.
  def test_concluded_stages_archive_regardless_of_holder
    ArchiveHolderGuard::CONCLUDED_STAGES.each do |stage|
      grade = decide(stage: stage, devops: NEAR_MISS, claim_live: true, abandoned: false)

      assert_equal :concluded, grade, "#{stage} work is already concluded"
      assert ArchiveHolderGuard.permitted?(grade)
    end
  end

  def test_a_live_stage_is_not_treated_as_concluded
    %w[designed building submitted reviewed assembled blocked].each do |stage|
      refute_equal :concluded, decide(stage: stage, devops: NEAR_MISS),
                   "#{stage} is live work — grading it concluded is how the near-miss happens"
    end
  end

  def test_permitted_is_a_closed_allowlist
    assert_equal %i[concluded unheld abandoned].sort, ArchiveHolderGuard::PERMITTED.sort,
                 "the permitted set is stated positively so a grade added later must be " \
                 "explicitly admitted rather than silently allowed through"
    %i[held working unverifiable].each do |grade|
      refute ArchiveHolderGuard.permitted?(grade), "#{grade} is a refusal"
    end
  end

  # ── THE DESK: ABSENCE IS AN ANSWER, UNREADABILITY IS NOT ────────────────────
  #
  # ClaimLease.abandoned? treats a nil desk reading as protective, which is right for
  # the heartbeat that asks from INSIDE the desk. An archive asks from the primary
  # checkout, so wiring nil through for every task would refuse every archive on the
  # machine — and a guard that refuses everything gets switched off.

  def test_a_desk_that_does_not_exist_is_a_real_negative_answer
    touched = ArchiveHolderGuard.desk_touched_for("/nope", exists: false,
                                                          reader: ->(_) { flunk("must not read a desk that is not there") })

    assert_equal false, touched,
                 "no desk means no uncommitted work in one to destroy — a REAL answer, not an unknown"
  end

  def test_a_desk_that_exists_but_cannot_be_read_stays_unknown
    touched = ArchiveHolderGuard.desk_touched_for("/desk", exists: true, reader: ->(_) { nil })

    assert_nil touched, "unreadable is not silent, and an unknown must protect the holder"
  end

  def test_a_desk_being_worked_in_reports_true
    assert_equal true, ArchiveHolderGuard.desk_touched_for("/desk", exists: true, reader: ->(_) { true })
  end

  # The two desk answers must reach the decision through ClaimLease unchanged, or the
  # distinction above is real in this file and lost in the wiring.
  def test_the_desk_answers_drive_the_abandoned_verdict
    assert ClaimLease.abandoned?(desk_touched: false),
           "an absent desk plus silence everywhere else is abandonment"
    refute ClaimLease.abandoned?(desk_touched: nil),
           "an unreadable desk is no evidence, and no evidence never frees a task"
  end

  # ── THE CHANNEL NAMED IN A :working REFUSAL ─────────────────────────────────

  def test_the_working_refusal_names_the_channel_that_spoke
    {
      { desk_touched: true } => "written to",
      { desk_touched: false, gate_in_flight: true } => "gate",
      { desk_touched: false, awaiting_approval: true } => "approval",
      { desk_touched: false, progress_age: 60 } => "durable artifact",
      { desk_touched: nil } => "could not be read"
    }.each do |channels, expected|
      assert_includes ArchiveHolderGuard.working_channel(channels), expected,
                       "the refusal must name WHICH channel kept the task: #{channels.inspect}"
    end
  end

  def test_the_working_channel_degrades_honestly
    message = ArchiveHolderGuard.working_channel(desk_touched: false, progress_age: 10**9)

    assert_includes message, "could not be shown abandoned",
                     "a channel combination that fits no branch must produce an honest fallback, " \
                     "never a confident lie about which channel spoke"
  end

  private

  def decide(stage:, devops:, claim_live: false, abandoned: false)
    ArchiveHolderGuard.decide(stage: stage, devops: devops, claim_live: claim_live, abandoned: abandoned)
  end

  def refusal(grade, stage:, devops:)
    ArchiveHolderGuard.refusal(grade, slug: "probe-task", stage: stage, devops: devops)
  end
end
