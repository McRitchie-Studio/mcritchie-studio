# frozen_string_literal: true

# One ATTEMPT at a named testing GATE — the branded checkpoints of the devops
# pipeline (docs/agents/modules/gates/):
#
#   G1 Cert       (task)    shape tiers + full-suite + rubocop (self-closing cert)
#   DoR (builder) (task)    the builder's dor-check verdict at submit (own gate)
#   DoR (review)  (task)    the primary reviewer's gate-zero dor-check (own gate)
#   G2a Primary   (task)    the primary senior review
#   G2b Light     (task)    the light senior review
#   G3 Candidate  (release) pre-QA gate + QA deploy + boot smoke + post_deploy
#   G4 Ship       (release) frozen-SHA gate + prod deploy + /up + smoke seal
#
# The two DoR gates are the OPTION-B split: cert (full-suite-check) owns g1_cert
# open+close on its own; the Definition-of-Ready verdict is its OWN gate, with a
# separate attempt for the builder (`dor`, dor-check at submit) and the reviewer's
# gate-zero (`dor_review`, dor-check --gate-role review). CI stays a handoff, not
# a gate.
#
# Each row is one attempt: started_at → finished_at, success (nil while in
# flight), and a `sops` jsonb list of the test SOPs executed inside the window
# ([{sop, cmd, tier, result, duration_ms, state, cause, reason, repo, at}]).
# Unlike the releases' first-write-wins stage stamps, RETRIES ARE FIRST-CLASS: a failed attempt
# closes and the re-run opens attempt n+1 — repeated cert/QA failures become
# visible signal instead of collapsing into one window.
#
# The write funnel is open!/append_sop!/close! (the API controller and the
# release conductor both call ONLY these). Concurrency backstop: a partial
# unique index allows at most one in-flight attempt per (subject, gate), so
# racing openers converge on one row. This is deliberately NOT an event spine —
# close! UPDATES the open row (the one write path that broadcasts on update).
class GateRun < ApplicationRecord
  # Order in this literal defines flow order (KEYS = GATES.keys): the two DoR
  # gates sit between g1_cert and the G2 review lanes.
  GATES = {
    "g1_cert"      => { "label" => "G1 Cert",      "grain" => "task" },
    "dor"          => { "label" => "DoR (builder)", "grain" => "task" },
    "dor_review"   => { "label" => "DoR (review)",  "grain" => "task" },
    "g2a_primary"  => { "label" => "G2a Primary",  "grain" => "task" },
    "g2b_light"    => { "label" => "G2b Light",    "grain" => "task" },
    "g3_candidate" => { "label" => "G3 Candidate", "grain" => "release" },
    "g4_ship"      => { "label" => "G4 Ship",      "grain" => "release" }
  }.freeze
  KEYS = GATES.keys.freeze
  TASK_KEYS    = GATES.select { |_, gate| gate["grain"] == "task" }.keys.freeze
  RELEASE_KEYS = GATES.select { |_, gate| gate["grain"] == "release" }.keys.freeze
  SUBJECT_TYPES = %w[task release].freeze

  # The keys a sops entry keeps (normalize_sop slices to these); `at` is stamped
  # server-side so entries are orderable even when the producer sends none.
  SOP_KEYS = %w[sop cmd tier result duration_ms state cause reason repo at].freeze

  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validates :subject_slug, presence: true
  validates :key, inclusion: { in: KEYS }
  validates :attempt, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :started_at, presence: true
  validate :key_grain_matches_subject_type

  scope :chronological, -> { order(started_at: :asc, id: :asc) }
  scope :in_flight, -> { where(finished_at: nil) }
  scope :for_subject, ->(type, slug) { where(subject_type: type, subject_slug: slug) }

  # Gate chips update live: open (create) and close (UPDATE — unlike the
  # append-only spines) both refresh the boards. Best-effort inside the
  # broadcaster so a transport failure never breaks the gate write.
  #
  # after_save_commit (= on: [:create, :update]) is LOAD-BEARING: registering
  # after_create_commit + after_update_commit with the SAME method name dedupes
  # to the last registration only (documented Rails callback-chain behavior), so
  # the pair silently dropped the create hook — gate OPENS never broadcast.
  after_save_commit :broadcast_gate_run
  # Keep the parent task's cached latest-attempt snapshot (Task::GatesProjection)
  # in step with every attempt write — open, append_sop, and close all land here.
  # Best-effort like the broadcaster: a projection failure never breaks the gate
  # write (refresh_gates_safely rescues + logs).
  after_save_commit :refresh_task_gates_projection

  # ---- write funnel (the ONLY writers) --------------------------------------

  # Find the in-flight attempt for (subject, gate) or create attempt n+1.
  # Idempotent by contract — a supervisor and a manual reviewer double-opening
  # converge on one row (the partial unique index breaks the race; the loser
  # retries and finds the winner's row).
  def self.open!(subject_type:, subject_slug:, key:, actor: nil, source: nil, metadata: {}, now: Time.current)
    retries = 0
    begin
      scope = for_subject(subject_type, subject_slug).where(key: key)
      run = scope.in_flight.first
      return run if run

      run = create!(
        subject_type: subject_type,
        subject_slug: subject_slug,
        key: key,
        attempt: scope.maximum(:attempt).to_i + 1,
        started_at: now,
        actor: actor,
        source: source,
        metadata: metadata.presence || {}
      )
      run.send(:stamp_g1_testing_window, :open)
      run
    rescue ActiveRecord::RecordNotUnique
      retries += 1
      retry if retries <= 2
      scope.in_flight.first || scope.order(:attempt).last
    end
  end

  # Append one executed-SOP entry to the gate's in-flight attempt (implicitly
  # opening one — appending IS evidence the gate is running).
  def self.append_sop!(subject_type:, subject_slug:, key:, sop:, actor: nil, source: nil, now: Time.current)
    run = open!(subject_type: subject_type, subject_slug: subject_slug, key: key,
                actor: actor, source: source, now: now)
    run.with_lock do
      run.update!(sops: run.sops + [normalize_sop(sop, now: now)])
    end
    run
  end

  # Close the in-flight attempt with its verdict. When NO attempt is open, a
  # lone verdict is still a REAL attempt — record it self-contained
  # (started_at == finished_at), e.g. a dor-check run with no preceding
  # full-suite window.
  def self.close!(subject_type:, subject_slug:, key:, success:, sops: [], actor: nil, source: nil, metadata: {}, now: Time.current)
    run = for_subject(subject_type, subject_slug).where(key: key).in_flight.first
    run ||= open!(subject_type: subject_type, subject_slug: subject_slug, key: key,
                  actor: actor, source: source, now: now)
    run.with_lock do
      run.update!(
        finished_at: now,
        success: success,
        sops: run.sops + Array(sops).map { |entry| normalize_sop(entry, now: now) },
        actor: run.actor.presence || actor,
        source: run.source.presence || source,
        metadata: run.metadata.merge(metadata.presence || {})
      )
    end
    run.send(:stamp_g1_testing_window, :close)
    run
  end

  # ---- reads -----------------------------------------------------------------

  # The newest attempt per gate key — what the UI chips render.
  def self.latest_by_key(subject_type:, subject_slug:)
    for_subject(subject_type, subject_slug)
      .order(:attempt, :id)
      .group_by(&:key)
      .transform_values(&:last)
  end

  # Batched latest_by_key for a LIST surface (/tasks/recent): one query for many
  # subjects -> { slug => { key => newest attempt } }. Same newest-attempt-wins
  # semantics as latest_by_key; a subject with no runs simply has no entry.
  def self.latest_by_key_for_subjects(subject_type:, subject_slugs:)
    where(subject_type: subject_type, subject_slug: subject_slugs)
      .order(:attempt, :id)
      .group_by(&:subject_slug)
      .transform_values { |runs| runs.group_by(&:key).transform_values(&:last) }
  end

  def in_flight?
    finished_at.nil?
  end

  def status
    return "in_flight" if in_flight?

    success ? "passed" : "failed"
  end

  # Wall-clock of the attempt; an in-flight run measures against now.
  def duration_seconds
    [((finished_at || Time.current) - started_at).to_i, 0].max
  end

  def label
    GATES.dig(key, "label") || key.to_s.humanize
  end

  def grain
    GATES.dig(key, "grain")
  end

  # A sops entry sliced to the known keys, `at`-stamped for ordering.
  def self.normalize_sop(entry, now: Time.current)
    raw = entry.respond_to?(:to_h) ? entry.to_h : {}
    normalized = raw.transform_keys(&:to_s).slice(*SOP_KEYS)
    normalized["duration_ms"] = normalized["duration_ms"].to_i if normalized["duration_ms"].present?
    normalized["at"] ||= now.iso8601
    normalized
  end

  private

  # A task-grain key on a release subject (or vice versa) is a caller bug —
  # reject it loudly rather than render a G1 chip on a release.
  def key_grain_matches_subject_type
    expected = GATES.dig(key.to_s, "grain")
    return if expected.nil? || subject_type.blank? || expected == subject_type

    errors.add(:key, "#{key} is a #{expected}-grain gate, not #{subject_type}")
  end

  def broadcast_gate_run
    DeploymentsBroadcaster.gate_run(self)
  end

  # Release-grain runs are intentionally NOT projected onto anything — release
  # surfaces read gate_runs directly (see Task::GatesProjection).
  def refresh_task_gates_projection
    return unless subject_type == "task"

    Task.find_by(slug: subject_slug)&.refresh_gates_safely
  end

  # Mirror the g1_cert testing WINDOW onto three flat tasks columns
  # (g1_testing_started_at / g1_testing_finished_at / g1_failed_at) so a task row
  # carries its cert window without walking gate_runs. ONLY the g1_cert task gate
  # moves them — every other gate (dor, dor_review, the G2 lanes) leaves them
  # untouched. Called from the write funnel (open!/close!): open stamps the
  # latest attempt's start; close stamps finished_at and toggles g1_failed_at
  # (set on a red close, cleared on a green retry). update_columns skips callbacks
  # (no re-entrancy, mirrors GatesProjection.refresh!) and the whole thing is
  # best-effort — a stamp failure never breaks the gate write.
  def stamp_g1_testing_window(phase)
    return unless subject_type == "task" && key == "g1_cert"

    columns =
      case phase
      when :open  then { g1_testing_started_at: started_at }
      when :close then { g1_testing_finished_at: finished_at, g1_failed_at: success ? nil : finished_at }
      end
    return if columns.blank?

    Task.find_by(slug: subject_slug)&.update_columns(columns) # rubocop:disable Rails/SkipsModelValidations
  rescue StandardError => e
    Rails.logger.warn("[gate-g1-stamp] #{subject_slug} #{phase}: #{e.class}: #{e.message}")
    nil
  end
end
