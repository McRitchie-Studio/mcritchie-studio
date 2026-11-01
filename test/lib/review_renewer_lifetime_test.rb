# frozen_string_literal: true

# [unit] A REVIEW RENEWER MUST NOT OUTLIVE ITS REVIEWER, and must not outlive its REVIEW. A
# reviewer is a SUBAGENT, not an OS process: anchor pid, session id and live-instance nonce
# are all the SESSION's, so an anchor-only renewer runs up to ShiftRenewer's 12h cap. A
# bounce (`bin/task block`, stage → `building`) must also end the loop. The anchor is held
# ALIVE in every test: a dying anchor passes against the original code. Drives the REAL
# `renew_loop` with fake board, clock and sleep. `bundle exec` is not optional: this
# requires minitest/mock, and bare `ruby` loads system minitest (6.x), a LoadError.
# History: task review-renewer-outlives-its-reviewer.

require "minitest/autorun"
require "minitest/mock"
require "json"
require "tmpdir"
require "stringio"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__)
require_relative "../../lib/claim_lease"

class ReviewRenewerLifetimeTest < Minitest::Test
  SESSION = "5c6d7e8f-9a0b-4c1d-8e2f-3a4b5c6d7e8f"
  SLUG = "task-under-review"

  Resp = Struct.new(:code, :body)

  # A board that serves the task at a stage the test controls and answers every
  # renewal 200 — the board's honest answer for a lease this instance still holds,
  # which is exactly what the dead reviewer's session still is.
  class Board
    attr_reader :renews
    attr_accessor :stage, :task_code

    def initialize(projects_dir:, stage:)
      @projects_dir = projects_dir
      @stage = stage
      @task_code = 200
      @renews = 0
    end

    def token = "tok"
    def projects_dir = @projects_dir
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(_method, path, _body = nil, **)
      if path.to_s.end_with?("/review_claim/renew")
        @renews += 1
        return Resp.new(200, JSON.generate({ data: { renewed: true, state: "renewed" } }))
      end
      return Resp.new(@task_code, "") unless @task_code == 200

      Resp.new(200, JSON.generate({ data: { slug: SLUG, stage: @stage } }))
    end
  end

  # Run the real renew_loop with the anchor held alive, and return the fake seconds it
  # ran for plus the renewals it posted. `after` lets a test change the world once the
  # loop has been renewing for a while — the bounce, for instance.
  def run_loop(stage:, task_code: 200, after: nil)
    Dir.mktmpdir do |proj|
      board = Board.new(projects_dir: proj, stage: stage)
      board.task_code = task_code
      cli = ReviewClaimCli.new(env: { "TASK_REVIEW_CLAIM_SESSION" => SESSION, "TASK_CLAIM_NONCE" => "inst-a" },
                               out: StringIO.new, err: StringIO.new)
      cli.instance_variable_set(:@api, board)

      now = Time.utc(2026, 9, 10, 3, 5, 0)
      started = now
      beats = 0
      # Both halves of the loop's time come from here: sleeping advances the clock, so
      # the loop's own lifetime check sees exactly the time it has "spent".
      cli.define_singleton_method(:sleep) do |seconds|
        now += seconds
        beats += 1
        after&.call(board, beats)
      end

      Time.stub(:now, -> { now }) do
        SessionIdentity.stub(:process_alive?, true) do
          cli.run(["renew-loop", SLUG, "--anchor-pid", "25559", "--anchor-start", "Tue Sep  8 16:08:00 2026"])
        end
      end
      { seconds: (now - started).round, renews: board.renews }
    end
  end

  # ── HALF 1: A DEAD REVIEWER INSIDE A LIVING SESSION ─────────────────────────

  def test_a_dead_reviewer_stops_being_renewed_while_its_session_lives
    # The reviewer dies; nothing observable changes. The session is open, the stage is
    # still `submitted`, the board still says "yours". This is the incident exactly.
    result = run_loop(stage: "submitted")

    window = ClaimLease::REVIEW_TTL_SECONDS
    assert_operator result[:seconds], :<=, window + ShiftRenewer::INTERVAL_SECONDS,
                    "a review renewer must stop once its review has outrun the measured continuous-review " \
                    "ceiling (#{window}s); it ran #{result[:seconds]}s against a session that never died. " \
                    "Past that point a dead reviewer and a live one are indistinguishable to every signal " \
                    "this machine has, and the lease still carries a full REVIEW_TTL of its own."
    assert_operator result[:renews], :<=, (window / ShiftRenewer::INTERVAL_SECONDS) + 1,
                    "and it must stop POSTING — #{result[:renews]} renewals kept a dead reviewer's task " \
                    "out of the review queue"
  end

  def test_the_bound_still_covers_every_measured_continuous_review
    # THE OTHER HALF OF THE PROPERTY: never lapse under a LIVE reviewer. The renewer's
    # window plus the lease it leaves behind must clear the longest continuous review
    # ever measured, or this fix trades a stranded task for a duplicated review.
    result = run_loop(stage: "submitted")
    covered = result[:seconds] + ClaimLease::REVIEW_TTL_SECONDS

    assert_operator covered, :>, ClaimLease::MEASURED_REVIEW_WINDOW_SECONDS[:sitting_max] * 2,
                    "the bound must leave a live review more than double the longest one ever measured"
  end

  # ── HALF 2: THE LOOP ENDS WHEN THE REVIEW ENDS ──────────────────────────────

  def test_a_bounce_ends_the_loop
    # The #1334 shape: renewing a live review, then the reviewer bounces it. `building`
    # is a verdict. Nothing else changes — the session is alive and the lease is still
    # the session's, which is precisely why the next review by a SIBLING reviewer in the
    # same session could be renewed by this loop as though it were its own.
    result = run_loop(stage: "submitted", after: ->(board, beats) { board.stage = "building" if beats == 3 })

    assert_operator result[:renews], :<=, 4,
                    "the review ended in a bounce at beat 3; #{result[:renews]} renewals followed it"
  end

  def test_a_task_already_off_submitted_is_renewed_zero_times
    %w[building blocked designed].each do |stage|
      assert_equal 0, run_loop(stage: stage)[:renews],
                   "a review claim protects a review of a SUBMITTED task; on `#{stage}` it protects nothing"
    end
  end

  def test_a_merge_still_ends_the_loop
    # THE CONTROL: the stages that already ended the loop still do.
    assert_equal 0, run_loop(stage: "reviewed")[:renews]
  end

  # ── AND THE UNCERTAINTY THAT MUST NOT END IT ────────────────────────────────

  def test_an_unreadable_board_does_not_end_a_live_review
    # A board we cannot read is not evidence the review ended. Stopping here would drop
    # a LIVE review's lease on a network blip and let a second reviewer pop the PR —
    # the collision the review lane's renewer exists to prevent. Only the time bound
    # ends this loop.
    result = run_loop(stage: "submitted", task_code: 503)

    assert_operator result[:renews], :>, 100, "an unreadable board must keep a live review renewing"
    assert_operator result[:seconds], :<=, ClaimLease::REVIEW_TTL_SECONDS + ShiftRenewer::INTERVAL_SECONDS
  end
end
