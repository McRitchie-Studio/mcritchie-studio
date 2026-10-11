# frozen_string_literal: true

class Task
  # IS SOMEONE HOLDING THIS TASK AND SAYING NOTHING?
  #
  # A review claim is a TTL lease its own detached renewer keeps alive, so a
  # reviewer that ends its turn ("waiting for CI") leaves the lease renewing while
  # nobody works. Two reviewer subagents sat like that for six hours on the night of
  # 2026-10-10/11, and the board showed both as healthy reviews. A build claim (the
  # desk, devops.claimed_session) has no lease at all.
  #
  # So this reads what the HOLDER would write if it were working: an atomic activity
  # (bin/agent-activity: AgentActivity, AgentAction), a task note (Activity) or a
  # task event, on this task. A claim with none of those for THRESHOLD is silent.
  # It is a read-side flag, computed per read: nothing is reclaimed, released or
  # stored, and every unknown reads as not silent.
  #
  # The writes are the task's, not the holder session's: a reviewer subagent shares
  # its harness session id with the session that spawned it, so a session-wide read
  # would let the parent's narration hide a stalled child.
  #
  # Claims read:
  #   review  `submitted`, with a LIVE TaskReviewClaim; its acquired_at counts as a
  #           write, so a fresh claim is never silent.
  #   build   `building`, not blocked (a block waits on someone else), with a
  #           recorded build claim (devops.claimed_session).
  class SilentClaim
    THRESHOLD = 30.minutes
    LABEL = "silent 30m+"

    # kind: "review" or "build"; holder: the soul or session named, or nil;
    # last_write_at: the newest write counted, or nil when none is known;
    # seconds: how long the claim has been silent.
    Result = Data.define(:kind, :holder, :last_write_at, :seconds) do
      def label = LABEL
      def age = ClaimLease.humanize_age(seconds)

      def sentence
        "#{kind} claim#{" held by #{holder}" if holder} has written nothing on this task for #{age}"
      end

      def as_json(*) = { "kind" => kind, "holder" => holder, "last_write_at" => last_write_at&.utc&.iso8601,
                         "seconds" => seconds.to_i, "label" => label }
    end

    # { slug => Result } for the silent claims among `tasks`, which carry their
    # task_events and review_claim preloaded (the boards do). Three grouped
    # queries, asked only for the tasks holding a claim.
    def self.by_slug(tasks, now: Time.current)
      claimed = tasks.select { |task| claim_kind(task, now: now) }
      writes = last_writes_by_slug(claimed.map(&:slug))
      claimed.each_with_object({}) do |task, found|
        result = self.for(task, last_write: writes[task.slug], now: now)
        found[task.slug] = result if result
      end
    end

    # The single-task read (the API, the task page).
    def self.for_task(task, now: Time.current)
      return nil unless claim_kind(task, now: now)

      self.for(task, last_write: last_writes_by_slug([task.slug])[task.slug], now: now)
    end

    # The newest activity write per task slug: atomic activities, their actions
    # and task notes.
    def self.last_writes_by_slug(slugs)
      return {} if slugs.empty?

      [
        AgentActivity.where(task_slug: slugs).group(:task_slug).maximum(:updated_at),
        AgentAction.where(task_slug: slugs).group(:task_slug).maximum(:occurred_at),
        Activity.where(task_slug: slugs).group(:task_slug).maximum(:created_at)
      ].each_with_object({}) do |times, newest|
        times.each { |slug, at| newest[slug] = [newest[slug], at].compact.max }
      end
    end

    # The task's review claim and newest event, from its loaded associations when
    # the board preloaded them, else by query. Never by loading the association on
    # the caller's instance: a broadcaster's task would keep a stale nil claim.
    def self.review_claim_of(task)
      loaded = task.association(:review_claim)
      loaded.loaded? ? loaded.target : TaskReviewClaim.find_by(task_slug: task.slug)
    end

    def self.newest_event_at(task)
      loaded = task.association(:task_events)
      return loaded.target.filter_map(&:occurred_at).max if loaded.loaded?

      TaskEvent.where(task_slug: task.slug).maximum(:occurred_at)
    end

    def self.claim_kind(task, now:)
      if task.stage == "submitted" && review_claim_of(task)&.live?(now: now)
        "review"
      elsif task.stage == "building" && !task.blocked? && task.devops_field("claimed_session").present?
        "build"
      end
    end

    # The Result for `task` when its claim is silent, else nil. `last_write` is
    # the newest activity write on the task (last_writes_by_slug).
    def self.for(task, last_write:, now: Time.current)
      kind = claim_kind(task, now: now)
      return nil unless kind

      claim = review_claim_of(task) if kind == "review"
      event_at = newest_event_at(task)
      last = [last_write, event_at, claim&.acquired_at].compact.max
      return nil if last.nil?

      seconds = now - last
      return nil if seconds < THRESHOLD

      holder = claim ? claim.holder_agent.presence : task.devops_field("built_by").presence
      Result.new(kind: kind, holder: holder, last_write_at: last, seconds: seconds)
    end
  end
end
