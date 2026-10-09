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
  #
  # DECLARED IN Release::AcceptedCertification, not here, and read back from there.
  # bin/release needs the same mapping for its `accepted` certification guard, and it
  # is a standalone script with NO ActiveRecord — it cannot reference a model constant.
  # Spelling the map a second time CLI-side is precisely how this gate went blind to
  # studio-engine before: the gate hard-coded "CI", every "Engine CI" run failed to
  # match, and every studio-engine PR resolved to :none. One literal, two readers.
  CI_WORKFLOW = Release::AcceptedCertification::DEFAULT_SUITE_WORKFLOW

  # The CI-SUITE workflows whose per-job progress feeds the board's CI meters: the
  # app repos' `CI`, each gem repo's own suite workflow (studio-engine's "Engine
  # CI"), AND each declared SIBLING suite lane (studio-engine's "Consumer CI"). The
  # ingest records CiCheckJob rows for exactly this set.
  #
  # THE SIBLINGS WERE ABSENT UNTIL 2026-08-26, and the absence was self-justifying:
  # a sibling lane had no per-job rows, so any reader that tried to fold one found
  # nothing, so the scope stayed narrow because widening it was "inert". Measured on
  # studio-engine `release` 9248a9c: the card drew a green 3/3 "Engine CI" meter for
  # SIX MINUTES while "Consumer CI" was 2/6 through the consumer suites on the same
  # commit, named only in the card's "also on this commit" row — beside a rung PILL
  # that ALREADY folds every suite lane (Ci::LadderRung.fold) and was therefore
  # amber. One card, two halves, disagreeing by construction.
  #
  # RECORDING A LANE IS NOT BLENDING IT — but be exact about what protects the gem,
  # because the obvious answer is the wrong one. It is NOT that the release track
  # stays narrow: Ci::ProgressReader#for_release now passes the full lane list too,
  # since that track previews a gate reading the workflow-BLIND check-runs endpoint.
  # Every DISPLAY of this repo may go red on a failing consumer.
  #
  # What holds is one layer down, and it never moved: CERTIFICATION still names
  # exactly ONE workflow per repo (Release::AcceptedCertification.workflow_for), and
  # that is the answer every gate and promote decision reads. So a failing consumer
  # can redden a bar without ever carrying the gem's verdict — a display and a
  # verdict are different claims, and only the first one widened here.
  #
  # DERIVED, never hand-listed: the gem map below plus
  # Release::AcceptedCertification::SIBLING_SUITE_WORKFLOWS, so declaring a lane in
  # the registry is what ingests it. Hand-adding the literal here instead would
  # leave the NEXT sibling lane recorded nowhere — the same shape of bug as the
  # hard-coded "CI" that blinded Ci::ReviewGate to every studio-engine PR.
  # test/models/ci_progress_workflow_consistency_test.rb asserts the property.
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
  # THE LIST ITSELF LIVES IN lib/gem_ci_workflows.rb; this points at it through
  # Release::AcceptedCertification, which is the model that reasons about which
  # workflow certifies a branch.
  #
  # BOTH HOPS ARE LOAD-BEARING, and this is a merge of two changes that each moved
  # this constant somewhere better. Release::AcceptedCertification owns the QUESTION
  # ("which workflow carries this repo's suite verdict, and is an unmapped gem an
  # oversight or a declaration?"), so callers ask it rather than reading a raw hash.
  # lib/ owns the DATA, because bin/release.rb is a standalone CLI — it reads
  # config/release_repos.yml and never boots Rails, so it cannot see a constant on an
  # AR model, and the gem publish gate needs this answer before an irreversible push.
  #
  # Keeping only one of the two hops was the tempting resolution and is the wrong one:
  # collapsing to the model re-blinds the CLI, and collapsing to the lib throws away
  # the UNMAPPED distinction. There is still exactly ONE literal, in lib/.
  GEM_CI_WORKFLOWS = Release::AcceptedCertification::GEM_SUITE_WORKFLOWS

  # Every SUITE lane a repo runs BESIDES its verdict-carrying one, flattened. The
  # registry is keyed by repo; the ingest filter only asks "is this a lane we
  # record", so the names are what it needs.
  SIBLING_CI_WORKFLOWS = Release::AcceptedCertification::SIBLING_SUITE_WORKFLOWS.values.flatten.freeze

  CI_PROGRESS_WORKFLOWS = ([CI_WORKFLOW] + GEM_CI_WORKFLOWS.values.compact + SIBLING_CI_WORKFLOWS)
                          .compact.uniq.freeze

  # The workflow name whose runs carry `repo`'s suite verdict. Accepts a bare slug
  # ("studio-engine") or an owner-qualified name ("McRitchie-Studio/studio-engine").
  # Returns nil for a gem that is registered but maps to no workflow — the caller
  # then means "newest run of any workflow", matching Ci::ProgressReader's contract
  # for an unmapped gem (solana-studio ships no suite → a blank, invisible track).
  # EVERY suite workflow for `repo` — the verdict-carrying one plus declared siblings
  # (studio-engine's "Consumer CI"). The Rails-side reader for
  # Release::AcceptedCertification::SIBLING_SUITE_WORKFLOWS, mirroring how
  # .ci_workflow_for reads the primary. Callers that must decide "did this run test
  # anything" ask here, so the answer is an ALLOW-LIST and a workflow nobody declared
  # — a nightly schedule, a CodeQL scan, a Pages build — fails closed instead of
  # counting as a verdict by default.
  def self.suite_workflows_for(repo)
    Release::AcceptedCertification.suite_workflows_for(repo, Release::Repos.config)
  rescue StandardError => e
    # ErrorLog, not a bare logger warn — .ci_workflow_for three lines below already
    # captures, and this became the HOTTER of the two when the ladder meter started
    # folding by lane. An unreadable registry degrades to the primary lane alone,
    # which is a QUIETER card, not a broken one; without a captured error that
    # silent narrowing is invisible.
    ErrorLog.capture!(e)
    [ci_workflow_for(repo)].compact
  end

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
