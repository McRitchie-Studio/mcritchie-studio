module Insights
  # Mines RESOLVED QA blocks into ActionGrade CANDIDATES — extending the learning
  # loop from grading spans to mining the block ledger.
  #
  # A QA block is a PRE-LABELED failure case: QA looked at the work and said "this
  # is wrong, here's why." When a task goes blocked -> resolved — a `qa_feedback`
  # Activity later cleared by a `resolves_feedback` handoff (Activity#blocking_feedback?
  # / #resolves_feedback?) — the pair is a complete, human-labeled defect. This
  # service turns each such block into a disposition:"not" ActionGrade candidate,
  # tying the block's feedback text (the lesson) to the span that caused the defect,
  # so the pipeline can surface it awaiting grade. That's free labeled training data.
  #
  # SPAN LINKAGE (the model-consistency decision): an ActionGrade targets EXACTLY
  # ONE of a raw action or a narrated span (its XOR) — there is no task/activity
  # target, and every existing read (insight_source / to_insight / the pipeline)
  # reaches provenance THROUGH that span. So a candidate hangs off an AtomicEvent,
  # never the task. We attribute the block to the NEWEST span on the blocked task
  # opened at/before the block was raised that is NOT already Alex-graded:
  #   * before the block  — the trajectory that produced the defect QA caught;
  #   * newest of those    — the tightest single proxy for "what caused it" (the last
  #                          thing the builder did before QA bounced it);
  #   * not already graded  — never clobber a human grade (uniqueness is per
  #                          event+grader) and never reuse one span across two blocks.
  # No attributable span (a pre-narration task, or all pre-block spans already
  # graded) -> we skip that block; a candidate can't hang off nothing.
  #
  # IDEMPOTENT: `source_activity_slug` (the block's Activity slug) carries a unique
  # partial index, and we guard on it before seeding — re-running (or a racing job)
  # never duplicates a candidate. Per-block failures are captured to ErrorLog and
  # skipped so one bad block can't abort a whole scan (backend discipline).
  #
  #   Insights::BlockMiner.mine!                          # scan every resolved block
  #   Insights::BlockMiner.mine!(task_slug: "some-task")  # scan one task's blocks
  class BlockMiner
    ALEX = ActionGrade::ALEX

    # A candidate's short label — the first few words of the block feedback (the
    # long_form carries the full text). Kept terse like the other grade slugs.
    SLUG_WORDS      = 7
    FALLBACK_SLUG   = "qa block regression".freeze

    def self.mine!(task_slug: nil)
      new(task_slug: task_slug).mine!
    end

    def initialize(task_slug: nil)
      @task_slug = task_slug.to_s.presence
    end

    # Seed a candidate for every resolved block not already mined. Returns the
    # ActionGrades newly created (skips + failures drop out).
    def mine!
      resolved_blocks.filter_map { |block| seed_candidate(block) }
    end

    private

    # The qa_feedback Activities that were later CLEARED by a resolves_feedback
    # handoff on the same task — the resolved blocks. Walked per task in
    # conversation order: each block stays pending until a resolving handoff closes
    # it, so an unresolved block (no later handoff) is never mined. Scoped to one
    # task when given (the after_create_commit trigger's narrow path).
    def resolved_blocks
      scope = Activity.where(activity_type: %w[qa_feedback handoff]).where.not(task_slug: nil)
      scope = scope.where(task_slug: @task_slug) if @task_slug

      resolved = []
      scope.conversation_order.group_by(&:task_slug).each_value do |activities|
        pending = []
        activities.each do |activity|
          if activity.blocking_feedback?
            pending << activity
          elsif activity.resolves_feedback?
            resolved.concat(pending)
            pending.clear
          end
        end
      end
      resolved
    end

    # Seed the ONE candidate for a block, or nil (already mined / no attributable
    # span / a captured failure). The unique index backstops the exists? guard
    # against a race — a RecordNotUnique there is a clean idempotent no-op.
    def seed_candidate(block)
      return if ActionGrade.exists?(source_activity_slug: block.slug)

      span = target_span_for(block)
      return unless span

      ActionGrade.create!(
        grader:               ALEX,
        disposition:          ActionGrade::NOT,
        atomic_event:         span,
        slug:                 candidate_slug(block),
        long_form:            block.description,
        source_activity_slug: block.slug
      )
    rescue ActiveRecord::RecordNotUnique
      nil
    rescue StandardError => e
      log = ErrorLog.capture!(e)
      log.target = block
      log.target_name = block.slug
      log.save!
      nil
    end

    # See SPAN LINKAGE above. nil when the block carries no task, or the task has no
    # ungraded span opened at/before the block.
    def target_span_for(block)
      return nil if block.task_slug.blank?

      graded = ActionGrade.by_grader(ALEX).where.not(atomic_event_id: nil).select(:atomic_event_id)
      AtomicEvent.where(task_slug: block.task_slug)
                 .where("opened_at <= ?", block.created_at)
                 .where.not(id: graded)
                 .order(opened_at: :desc, seq: :desc, id: :desc)
                 .first
    end

    def candidate_slug(block)
      words = block.description.to_s.split(/\s+/).reject(&:blank?)
      words.first(SLUG_WORDS).join(" ").presence || FALLBACK_SLUG
    end
  end
end
