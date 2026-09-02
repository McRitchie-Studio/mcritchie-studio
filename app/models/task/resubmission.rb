# frozen_string_literal: true

class Task
  # IS THIS `building` TASK A FRESH BUILD, OR A RESUBMISSION CARRYING A SEND-BACK?
  #
  # A `--kind rework` block does NOT move a task to the `blocked` stage — it sets a
  # block ATTRIBUTE and lands the task back on `building` (Task#block!). That is the
  # right routing: `blocked` reads as "not in the pipeline's court" (an env blocker, a
  # dependency, QA waiting on someone else), and a rework is squarely in the BUILDER'S
  # court. But it leaves the board unable to say the one thing a reader needs, because
  # a bounced task and a never-reviewed task are the same shape: stage `building`, a
  # green PR, no stage marker. `bin/task list --stage blocked` returns zero, and
  # `blocked_at` / `block_kind` are null BY DESIGN.
  #
  # WHAT IS MEASURED, on stale-engine-web3-comments / turf PR #513, 2026-09-01→02:
  #
  #   1. A re-promotion on a wrong read: `unresolved_feedback`, `blocked_at` and
  #      `block_kind` all answered None, so the task was moved to `submitted` and a
  #      reviewer briefed that a merge-ready verdict was on record. `bin/task bounces`
  #      said BREAKER: TRIPPED the whole time, and the head had not moved (029a945b at
  #      the bounce and after) — so the reviewer was about to review the blocked tree.
  #   2. The structural reason that read failed: those three fields describe the
  #      `blocked` STAGE and a LIVE block. Asking them about a BOUNCE asks a question
  #      they cannot answer.
  #
  # ONE MECHANISM IN THE ORIGINAL REPORT WAS FALSIFIED, and it is recorded here so it
  # is not re-derived from the same adjacency. The report held that a reviewer's
  # one-line zap pushed #513 `submitted` → `building`, out of `claim-next-review`'s
  # reach. A reviewer then did exactly that on turf PR #518 and the task STAYED at
  # `submitted` (head f1a847a9, `bounces` CLEAR, review claim released) — so a zap by
  # itself does not demote a task out of the queue. The zap and the demotion merely
  # co-occurred on #513, and causation was inferred from adjacency: the very error this
  # class exists to stop. WHAT actually moved #513 to `building` overnight is still
  # unidentified.
  #
  # THAT GAP DOES NOT WEAKEN ANY OF THIS — it is the point. A `building` task carries no
  # memory of having been bounced REGARDLESS of what moved it there, so the fix cannot
  # and must not depend on identifying the transition. It reads the ledger and the tree,
  # both of which survive any route into `building`.
  #
  # WHY IT IS EXPENSIVE, NOT MERELY UNTIDY. The two-bounce circuit breaker escalates a
  # repeat send-back to Mr. McRitchie by design. A correct verdict on unaddressed
  # feedback is another block — send-back 2 of 2 — so an invisible finding plus a
  # one-bounce ceiling escalates to the operator over a resubmission that never
  # happened.
  #
  # THE TRAP THAT MAKES THE NAIVE VERSION USELESS. `unresolved_feedback` holds the TEXT
  # of what was said. It is cleared ONLY by an explicit `bin/task note --resolves-feedback`
  # handoff (Task.unresolved_feedback_by_slug), never by the work that answers it
  # landing. So "does this task have unresolved feedback?" CANNOT be answered by testing
  # that field for emptiness: a builder who fixed the finding and reshipped without the
  # ceremony reads as blocked forever, and — instance 2 — a builder who ran the ceremony
  # without doing the work reads as clear. Both directions were measured.
  #
  # THE HONEST SIGNAL IS THE TREE, NOT THE PROSE. A resubmission that ADDRESSED the
  # finding has a different head than the one the reviewer bounced; one that did not has
  # the same head. So this asks the ONE question the prose cannot fake: has the code
  # moved since the bounce? A `resolves_feedback` handoff deliberately does NOT override
  # an unmoved head — that claim is precisely what lied in instance 2.
  #
  # WHERE THE HEAD COMES FROM, and the claim that turned out to be false. The review SOP
  # records a before-spawn head (`gh pr view --json headRefOid`) and Carl re-reads it
  # before merging — but that head lives in the ORCHESTRATOR'S SESSION and is never
  # written to the board. `bin/task block` stamps only summary/kind/breaker_ack into the
  # qa_feedback row. So the head at the bounce is NOT already recorded, and this reads it
  # instead from our own ingested GitHub Actions rows (GithubWorkflowRun), which carry
  # head_sha + run_started_at per branch — the same tree resolver Ci::ReviewGate uses for
  # the merge gate, so the two can never drift on which tree a branch is at. That source
  # also works RETROACTIVELY, which a new stamp would not: the three instances above are
  # visible the moment this ships.
  #
  # FAIL-SAFE POSTURE, mirroring BounceLedger. A head we cannot resolve is :unknown, and
  # :unknown NEVER renders as "addressed". Un-ingested CI (a push whose run has not
  # landed yet) reads :unaddressed for as long as the ingest lag, which over-warns rather
  # than under-warns — the same trade the circuit breaker makes, and the correct one when
  # the cost of a false clear is an operator escalation.
  class Resubmission
    # No countable send-back on the ledger — an ordinary build.
    FRESH = :fresh
    # Bounced, and the head is the SAME one the reviewer sent back. Nothing landed.
    UNADDRESSED = :unaddressed
    # Bounced, and the head MOVED after the bounce — work answering it landed.
    ADDRESSED = :addressed
    # Bounced, but we hold no head evidence on one side or the other. Never "addressed".
    UNKNOWN = :unknown

    STATES = [ FRESH, UNADDRESSED, ADDRESSED, UNKNOWN ].freeze

    # The stages where "fresh build or resubmission?" is a live question. Past
    # `submitted` the work has been accepted and the ledger is history, not a warning.
    ACTIVE_STAGES = %w[building submitted].freeze

    # Newest-run ordering, mirroring Ci::ReviewGate::LATEST_RUN_ORDER — the same tree
    # resolver, so the board and the merge gate cannot disagree about a branch's head.
    LATEST_RUN_ORDER = Ci::ReviewGate::LATEST_RUN_ORDER

    attr_reader :task, :state, :bounce_count, :last_bounce_at, :head_at_bounce, :head_now

    # Load the CLI's bounce classifier for its KIND constants, so the board counts a
    # send-back exactly as `bin/task bounces` does. Same lazy-require precedent as
    # Ci::ReviewGate.require_ci_status; the file is plain Ruby (json + net/http only).
    def self.require_bounce_ledger
      require Rails.root.join("bin", "lib", "bounce_ledger.rb").to_s
    end

    # Which qa_feedback rows are a SEND-BACK TO THE BUILDER. `rework` is the send-back
    # itself; an unclassifiable row counts too (rows predating kind-stamping, and any
    # `bin/task note --qa-feedback`), because in a safety read the safe reading of an
    # unknown row is that it might be a bounce. `dependency` (the escalation) and
    # `environment` (a blocked desk) are not bounces. Delegated so the rule lives in
    # ONE place.
    def self.countable_kinds
      require_bounce_ledger
      BounceLedger::COUNTABLE_KINDS
    end

    def self.known_kinds
      require_bounce_ledger
      BounceLedger::KINDS
    end

    # Is this qa_feedback Activity a countable send-back? Mirrors BounceLedger.build_row's
    # classification: an unrecognised kind normalises to "unknown", which counts.
    def self.countable?(activity)
      kind = activity.metadata.to_h["kind"].to_s.strip
      kind = BounceLedger::UNKNOWN_KIND unless known_kinds.include?(kind)
      countable_kinds.include?(kind)
    end

    def self.for(task)
      for_tasks([ task ]).fetch(task.slug)
    end

    # BATCHED for the board, which renders many cards and has spent real effort killing
    # per-card queries. Two queries total, and the second one runs only for the tasks
    # that ACTUALLY bounced — normally a handful, often none — so a board with no
    # send-backs on it pays for one activities read and nothing else.
    def self.for_tasks(tasks)
      tasks = Array(tasks)
      return {} if tasks.empty?

      require_bounce_ledger
      bounces = bounces_by_slug(tasks.map(&:slug))
      heads = head_index_for(tasks.select { |task| bounces.key?(task.slug) })

      tasks.index_by(&:slug).transform_values { |task| build(task, bounces[task.slug], heads) }
    end

    # slug => { count:, last_at: } over the COUNTABLE rows only. One query.
    def self.bounces_by_slug(slugs)
      slugs = Array(slugs).map(&:to_s).reject(&:blank?)
      return {} if slugs.empty?

      Activity.where(task_slug: slugs, activity_type: "qa_feedback")
              .conversation_order
              .each_with_object({}) do |activity, acc|
        next unless countable?(activity)

        entry = acc[activity.task_slug] ||= { count: 0, last_at: nil }
        entry[:count] += 1
        entry[:last_at] = activity.created_at
      end
    end

    # [repo, branch] => the branch's ingested runs, newest first. ONE query across every
    # bounced task. The workflow filter is applied per task in #build, mirroring
    # Ci::ReviewGate.latest_ci_sha: WHICH TREE a branch is at is the suite workflow's
    # question, and a downstream consumer run alone resolves no tree.
    #
    # The WHERE is a cross-product of the repos and the branches, not an exact pair
    # match, so it can fetch a few rows no task asked for. That is deliberate — one
    # query beats N — and it is SAFE because the grouping is keyed on the exact
    # [repo, branch] pair, so a stray row can never be read as another task's head.
    # Branch names are task-unique in practice, which keeps the overfetch near zero.
    def self.head_index_for(tasks)
      keys = tasks.filter_map { |task| repo_branch_for(task) }.uniq
      return {} if keys.empty?

      runs = GithubWorkflowRun.where(repo: keys.map(&:first).uniq, head_branch: keys.map(&:last).uniq)
                              .order(Arel.sql(LATEST_RUN_ORDER))
      runs.group_by { |run| [ run.repo, run.head_branch ] }
    end

    # ["owner/repo", "feat/branch"] for a task, or nil when it names neither.
    def self.repo_branch_for(task)
      repo = Ci::ReviewGate.primary_repo_for(task).to_s
      branch = Ci::ReviewGate.branch_for(task).to_s
      return nil if repo.empty? || branch.empty?

      [ Ci::ReviewGate.nwo_for(repo), branch ]
    end

    def self.build(task, bounce, heads)
      return new(task: task, state: FRESH) if bounce.nil? || bounce[:count].to_i.zero?

      key = repo_branch_for(task)
      workflow = key ? GithubWorkflowRun.ci_workflow_for(key.first) : nil
      runs = key ? Array(heads[key]).select { |run| run.workflow_name == workflow } : []

      last_at = bounce[:last_at]
      now_sha = runs.first&.head_sha.presence
      # The head as of the bounce: the newest run that had STARTED when the reviewer
      # blocked. `run_started_at` is nullable, so fall back to the ingest timestamp
      # rather than dropping the row and silently reading further back in history.
      at_sha = runs.find { |run| (run.run_started_at || run.created_at) <= last_at }&.head_sha.presence

      state = if now_sha.nil? || at_sha.nil?
                UNKNOWN
              elsif now_sha == at_sha
                UNADDRESSED
              else
                ADDRESSED
              end

      new(task: task, state: state, bounce_count: bounce[:count], last_bounce_at: last_at,
          head_at_bounce: at_sha, head_now: now_sha, head_tracked: !key.nil?)
    end

    def initialize(task:, state:, bounce_count: 0, last_bounce_at: nil, head_at_bounce: nil,
                   head_now: nil, head_tracked: false)
      @task = task
      @state = state
      @bounce_count = bounce_count.to_i
      @last_bounce_at = last_bounce_at
      @head_at_bounce = head_at_bounce
      @head_now = head_now
      @head_tracked = head_tracked
    end

    # Does this task even NAME a PR whose head could be compared? A task with no
    # branch/pr_url has no tree to ask about, which is a different fact from "we
    # looked and found no run" — and saying HEAD UNKNOWN about it would read as broken
    # instrumentation rather than as the plain absence of a PR.
    def head_tracked?
      @head_tracked
    end

    def resubmission?
      state != FRESH
    end

    # Should the board SAY something? Only while the work is still in the build/review
    # lane — a shipped task's ledger is history, not a warning.
    def surfaced?
      resubmission? && ACTIVE_STAGES.include?(task.stage)
    end

    # The two-bounce circuit breaker's state, as the board's own read rather than a
    # command the reader has to know to run. One prior send-back means the NEXT block is
    # a review deadlock, which escalates to the operator.
    def breaker_tripped?
      bounce_count.positive?
    end

    def unaddressed?
      state == UNADDRESSED
    end

    # The glance-level headline. Deliberately says what is KNOWN, never "looks fine".
    def label
      count = send_back_phrase.upcase
      case state
      when UNADDRESSED then "RESUBMISSION · FEEDBACK NOT ADDRESSED"
      when ADDRESSED   then "RESUBMISSION · FEEDBACK ADDRESSED · #{count}"
      when UNKNOWN     then head_tracked? ? "RESUBMISSION · HEAD UNKNOWN · #{count}" : "RESUBMISSION · #{count}"
      end
    end

    # Red for an unmoved head — the reviewer would be re-reading the tree they bounced.
    # Amber otherwise: a resubmission is not a problem, but the armed breaker means the
    # next send-back escalates, and the reader should know before they act.
    def scheme
      unaddressed? ? :red : :amber
    end

    def title
      case state
      when UNADDRESSED
        "#{send_back_phrase} on record, and the PR head has not moved since " \
          "(#{short_sha(head_at_bounce)}). The feedback has not been addressed — " \
          "review would re-read the tree it bounced."
      when ADDRESSED
        "#{send_back_phrase} on record; the head moved after the bounce " \
          "(#{short_sha(head_at_bounce)} → #{short_sha(head_now)}). The circuit breaker is " \
          "armed, so the next send-back escalates to Mr. McRitchie."
      when UNKNOWN
        if head_tracked?
          "#{send_back_phrase} on record, but no ingested CI run resolves this branch's head " \
            "on one side of the bounce — so whether the feedback was addressed is UNKNOWN. " \
            "Check the PR before reviewing or reshipping."
        else
          "#{send_back_phrase} on record. This task records no PR branch, so there is no head " \
            "to compare and whether the feedback was addressed cannot be read from the tree. " \
            "The circuit breaker is armed: the next send-back escalates to Mr. McRitchie."
        end
      end
    end

    def send_back_phrase
      "#{bounce_count} send-back#{"s" if bounce_count != 1}"
    end

    def short_sha(sha)
      sha.to_s.empty? ? "unknown" : sha.to_s[0, 8]
    end
  end
end
