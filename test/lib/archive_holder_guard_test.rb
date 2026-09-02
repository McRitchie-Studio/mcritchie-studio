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

  # And each paint key alone must trip the refusal. Two shapes are exercised because
  # the board stores both: `builders` is a LIST, which is why `present?` has an Array
  # branch — a naive `.to_s.empty?` reads `[]` as present and would refuse every
  # archive.
  PAINT_VALUES = {
    "mascot" => "omanyte",
    "built_by" => "carl",
    "builders" => %w[carl steffon],
    "builders_unattributed" => "1",
    "persona" => "carl"
  }.freeze

  def test_every_paint_key_alone_is_unverifiable
    ArchiveHolderGuard::PAINT_KEYS.each do |key|
      value = PAINT_VALUES.fetch(key) { flunk("PAINT_KEYS gained #{key} with no fixture value") }
      grade = decide(stage: "building", devops: { key => value })

      assert_equal :unverifiable, grade, "#{key} shows somebody was here while naming no session"
    end
  end

  # EVERY PAINT KEY MUST BE A KEY THE BOARD CAN ACTUALLY STORE, or the refusal it is
  # meant to trigger can never fire and the gate promises coverage it cannot deliver.
  # `agent_slug` sat in this list for one review while being a top-level `tasks`
  # COLUMN that Task.normalize_devops_metadata drops — nil on all 1,575 board tasks.
  # This test is what stops the next column name sneaking back in.
  def test_no_paint_key_shadows_a_top_level_column
    column_names = %w[agent_slug stage slug title priority release_slug block_kind
                      po_size dev_size actual_size merged]

    (ArchiveHolderGuard::PAINT_KEYS & column_names).each do |key|
      flunk("PAINT_KEYS carries #{key}, which is a top-level Task column and never " \
            "survives into metadata.devops — a paint key nothing can populate is a " \
            "refusal that can never fire")
    end
  end

  # The near-miss's own shape, spelled by a different subsystem. ReviewerSelector
  # writes `builders_unattributed` to mean "a session worked this while naming no
  # soul", which is word-for-word this file's definition of :unverifiable — and it
  # graded :unheld, the "nobody was ever here" verdict, until this cut.
  def test_an_unattributed_builder_is_unverifiable_not_unheld
    grade = decide(stage: "building", devops: {
                     "repositories" => ["mcritchie-studio"], "builders_unattributed" => "1"
                   })

    assert_equal :unverifiable, grade,
                 "a session worked this and named no soul — that is the unknown holder " \
                 "this gate exists for, not an unclaimed task"
    refute ArchiveHolderGuard.permitted?(grade)
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
    assert ArchiveHolderGuard.abandonable?(desk_touched: false),
           "an absent desk plus silence everywhere else is abandonment"
    refute ArchiveHolderGuard.abandonable?(desk_touched: nil),
           "an unreadable desk is no evidence, and no evidence never frees a task"
  end

  # ── WORK AT RISK, NOT BOARD ACTIVITY ────────────────────────────────────────
  #
  # THE MEASURED DEFECT this section pins. Graded against the live board on
  # 2026-09-02, the first cut of the gate refused 31 of 34 live tasks; all 31 were
  # `:working`, all 31 were held by board progress, and 16 had NO DESK AT ALL.
  # `progress_age` there is Task#holder_liveness_seconds_ago, which degrades to the
  # age of the task's own CREATE when no holder owns an artifact — so a task created
  # 72 seconds ago read as somebody working.

  # The exact shape of the 16: identifiable holder, no desk, and a board write so
  # fresh it is inside the idle window. Nothing uncommitted exists to protect.
  def test_a_task_with_no_desk_archives_however_fresh_its_board_activity
    grade = decide(stage: "designed", devops: { "session_id" => SESSION },
                   abandoned: ArchiveHolderGuard.abandonable?(desk_touched: false))

    assert_equal :abandoned, grade,
                 "no desk means no uncommitted work for the archive to destroy — holding " \
                 "this on a board timestamp is what refused 16 of 34 live tasks"
    assert ArchiveHolderGuard.permitted?(grade)
  end

  # THE SELF-POISONING, as an A/B rather than an anecdote. Every `bin/task` write
  # lands a TaskEvent and resets the board clock, so a gate that reads it refuses to
  # archive whatever it has just triaged — the trap archive-shipped.md already
  # documents for the reclaim gate ("⛔ Step 7 BLOCKS step 8"). A gate must not
  # consult a signal its own verb writes.
  #
  # Both halves are asserted in one test ON PURPOSE. The first is what makes the
  # second mean anything: it shows the board clock is a LIVE channel that really does
  # flip ClaimLease's answer on identical desk facts, so the archive gate's differing
  # verdict is a deliberate divergence and not two calls that never disagreed. Drop
  # the first assertion and the second passes against a gate that reads the clock in
  # a code path this fixture happens not to reach.
  def test_the_board_clock_moves_the_lease_verdict_and_never_the_archive_verdict
    fresh = 60 # a board write a minute ago — well inside the 1h29m idle window

    refute ClaimLease.abandoned?(desk_touched: false, progress_age: fresh),
           "the LEASE question still consults the board clock — this is the false " \
           "'still working' the archive gate used to inherit for 31 of 34 live tasks"
    assert ArchiveHolderGuard.abandonable?(desk_touched: false),
           "the ARCHIVE question does not: a durable board artifact survives the " \
           "archive, so it is not work the archive can destroy"
  end

  # The channel is not merely defaulted away, it is GONE — a caller who passes it in
  # good faith is told so at the call site rather than silently getting nothing.
  def test_board_progress_cannot_be_passed_back_in_by_accident
    error = assert_raises(ArgumentError) do
      ArchiveHolderGuard.abandonable?(desk_touched: false, progress_age: 60)
    end

    assert_match(/progress_age/, error.message,
                 "re-wiring the board clock into the archive gate must be a decision " \
                 "somebody makes on purpose, not a keyword that quietly does nothing")
  end

  # THE OTHER HALF OF THE FAILURE, and the reason this is a narrowing rather than a
  # gutting. Refusing everything and archiving everything are the same bug wearing
  # different clothes; a desk being written into still stops the archive cold, and a
  # board that has been silent for eleven days does not change that.
  def test_a_desk_being_worked_in_still_refuses_however_stale_the_board
    grade = decide(stage: "building", devops: { "session_id" => SESSION },
                   abandoned: ArchiveHolderGuard.abandonable?(desk_touched: true))

    assert_equal :working, grade,
                 "uncommitted work in a live desk is exactly what this gate protects"
    refute ArchiveHolderGuard.permitted?(grade)
  end

  # The two channels that keep a QUIET desk. Both attest work at risk: a cert writes
  # nothing into its desk for up to the measured 94-minute p99, and a task parked on
  # the operator has work sitting in front of a human.
  def test_the_channels_that_keep_a_quiet_desk_survive_the_narrowing
    refute ArchiveHolderGuard.abandonable?(desk_touched: false, gate_in_flight: true),
           "a cert writes nothing into its desk while it runs, so a quiet desk mid-cert is a working one"
    refute ArchiveHolderGuard.abandonable?(desk_touched: false, awaiting_approval: true),
           "a task waiting on Mr. McRitchie is blocked on a human, not abandoned"
  end

  # ── THE CHANNEL NAMED IN A :working REFUSAL ─────────────────────────────────

  def test_the_working_refusal_names_the_channel_that_spoke
    {
      { desk_touched: true } => "written to",
      { desk_touched: false, gate_in_flight: true } => "gate",
      { desk_touched: false, awaiting_approval: true } => "approval",
      { desk_touched: nil } => "could not be read"
    }.each do |channels, expected|
      assert_includes ArchiveHolderGuard.working_channel(channels), expected,
                       "the refusal must name WHICH channel kept the task: #{channels.inspect}"
    end
  end

  # THE BRANCHES MUST MATCH THE CHANNELS ONE FOR ONE. A renderer that still knew how
  # to blame the board clock would let the gate refuse for one reason and report
  # another — the refusal's whole job is to name what actually held it, and the
  # acceptance criterion here is that it does.
  def test_the_refusal_never_blames_the_board_clock
    message = ArchiveHolderGuard.working_channel(desk_touched: false, progress_age: 60)

    refute_includes message, "durable artifact",
                     "board progress is not a channel of this gate, so it must never be " \
                     "offered as the reason a task was kept"
    assert_includes message, "could not be shown abandoned",
                     "an unrecognised channel combination must produce the honest fallback, " \
                     "never a confident lie about which channel spoke"
  end

  def test_the_working_channel_degrades_honestly
    message = ArchiveHolderGuard.working_channel(desk_touched: false)

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
