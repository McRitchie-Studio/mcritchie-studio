# A cached GitHub Actions run, one row per Actions `workflow_run`, keyed on the
# immutable run_id. Written only by GithubWorkflowRunIngestJob (which owns the
# idempotent, monotonic upsert). This model stays thin: it is the read surface
# the board queries for CI status, plus the canonical status ordering.
class GithubWorkflowRun < ApplicationRecord
  # GitHub's workflow_run lifecycle, in the order it PROGRESSES. The ingest job
  # uses these ranks to advance a run monotonically and never regress it (a late
  # `in_progress` re-delivery must not clobber a `completed` row).
  STATUS_ORDER = { "queued" => 0, "in_progress" => 1, "completed" => 2 }.freeze
  # COLUMN `run_attempt` — which ATTEMPT the stored `conclusion` belongs to, NOT
  # merely the newest attempt seen. GitHub re-runs a workflow under the SAME
  # run_id and bumps run_attempt, so this is what separates a newer verdict (which
  # must win) from a late replay of an older one (which must not). nil on rows
  # ingested before the column existed — read as 0, which is what an un-re-run
  # workflow effectively was. GithubWorkflowRunIngestJob#upsert_run! is the
  # INGEST writer, and it advances the column and the conclusion TOGETHER:
  # letting them drift apart is precisely the defect that made this column
  # necessary. Ci::RunReconciler is the only other writer — an operator-run
  # one-time heal for rows stored before the ingest fix.

  # The one workflow whose per-job progress feeds the board's CI bars — the single
  # source both the ingest (which CiCheckJob rows to record) and Ci::ProgressReader
  # (which run's SHA to fold) key on.
  CI_WORKFLOW = "CI"

  # The CI-SUITE workflows whose per-job progress feeds the board's release CI
  # meters: the app repos' `CI` PLUS each gem repo's own suite workflow
  # (studio-engine's "Engine CI"). The ingest records CiCheckJob rows ONLY for
  # these — a gem's downstream "Consumer CI" runs on the same `main` SHA but is NOT
  # a surfaced track, so it is never recorded. Ci::ProgressReader additionally
  # SCOPES each track's fold to its own workflow, so even a sibling workflow that
  # slips in never blends into a gem's track. DERIVED from GEM_CI_WORKFLOWS below,
  # which Ci::ProgressReader now aliases rather than duplicates — so the two can no
  # longer drift apart. test/models/ci_progress_workflow_consistency_test.rb asserts
  # the property rather than comparing two hand-written lists.
  #
  # Which workflow carries a GEM repo's OWN suite verdict. A gem does not run a
  # workflow called "CI": studio-engine runs "Engine CI" (its own suite) and
  # "Consumer CI" (the downstream apps' suites against it). Only the former is the
  # gem's verdict, so the name is load-bearing in both directions.
  #
  # THIS IS THE ONE PLACE a repo's CI workflow name is decided. Every reader —
  # Ci::ReviewGate (the review pop) and Ci::ProgressReader (the release meters) —
  # resolves through .ci_workflow_for rather than naming a workflow itself.
  # Centralised deliberately: the gate previously hard-coded the literal CI_WORKFLOW,
  # so every studio-engine PR resolved to no runs, read :none, and was permanently
  # unclaimable by pr-review. Adding a second literal somewhere would leave the NEXT
  # gem just as blind; asserting the property is what
  # test/models/ci_progress_workflow_consistency_test.rb now does.
  #
  # EVERY registered gem must appear here — the consistency test enforces it. A nil
  # value is an EXPLICIT declaration that the gem ships no suite workflow
  # (solana-studio runs none), not an accident. The distinction matters because a
  # reader cannot tell "unmapped by oversight" from "genuinely has no suite", and
  # Ci::ReviewGate treats an unresolved workflow as NOT-GREEN rather than guessing.
  GEM_CI_WORKFLOWS = {
    "studio-engine" => "Engine CI",
    "solana-studio" => nil # ships no suite workflow — declared, not overlooked
  }.freeze

  CI_PROGRESS_WORKFLOWS = ([CI_WORKFLOW] + GEM_CI_WORKFLOWS.values.compact).freeze

  # The workflow name whose runs carry `repo`'s suite verdict. Accepts a bare slug
  # ("studio-engine") or an owner-qualified name ("McRitchie-Studio/studio-engine").
  # Returns nil for a gem that is registered but maps to no workflow — the caller
  # then means "newest run of any workflow", matching Ci::ProgressReader's contract
  # for an unmapped gem (solana-studio ships no suite → a blank, invisible track).
  def self.ci_workflow_for(repo)
    slug = repo.to_s.split("/").last.to_s
    return GEM_CI_WORKFLOWS[slug] if Release::Repos.gem?(slug)

    CI_WORKFLOW
  rescue StandardError => e
    # Release::Repos reads config/release_repos.yml. An unreadable/malformed registry
    # must not 500 the claim-next-review pop, so degrade to the APP workflow: an app
    # repo keeps working, and a gem then resolves "CI", matches nothing, and reads
    # :none — not-green, which is the safe direction for a merge gate.
    ErrorLog.capture!(e)
    CI_WORKFLOW
  end

  validates :repo, :run_id, :status, presence: true
  validates :run_id, uniqueness: true

  scope :for_sha, ->(sha) { where(head_sha: sha) }
  scope :for_repo, ->(full_name) { where(repo: full_name) }

  # Rank of a lifecycle status, or -1 for anything unknown so it never outranks a
  # real status. Class-level so the job can compare an incoming string against a
  # stored one without instantiating.
  def self.status_rank(status)
    STATUS_ORDER.fetch(status.to_s, -1)
  end

  def terminal?
    status == "completed"
  end
end
