module ReviewEventsHelper
  ReviewLane = Struct.new(:role, :label, :description, :agent, :events, :moments, :top_agents, :started_at,
                          keyword_init: true)
  ReviewMomentTiming = Struct.new(:event, :seconds, :status, :anchor_at, :occurred_at, keyword_init: true)

  def review_event_lanes(task, agents, events, process: nil)
    process ||= ReviewProcessHub.new(agents: agents)
    by_role = Array(events).group_by(&:review_role)
    by_slug = agents.index_by(&:slug)
    reviewers = latest_review_reviewer_records(task)
    started_at = review_started_at_for(task, events)

    Task::REVIEW_ROLES.map do |role|
      slug = reviewers.find { |r| Task.normalize_review_role(r["weight"]) == role }&.dig("slug")
      slug ||= Array(events).reverse.find { |event| event.review_role == role && event.actor.present? }&.actor
      agent = by_slug[slug.to_s]

      ReviewLane.new(
        role: role,
        label: review_role_label(role),
        description: review_role_description(role),
        agent: agent || unresolved_review_agent(slug, role),
        events: Array(by_role[role]),
        moments: Task::REVIEW_MOMENTS.fetch(role),
        top_agents: process.top_agents(role),
        started_at: started_at
      )
    end
  end

  def review_process_lanes(process)
    Task::REVIEW_ROLES.map do |role|
      ReviewLane.new(
        role: role,
        label: review_role_label(role),
        description: review_role_description(role),
        agent: nil,
        events: [],
        moments: Task::REVIEW_MOMENTS.fetch(role),
        top_agents: process.top_agents(role),
        started_at: nil
      )
    end
  end

  def review_role_label(role)
    Task.normalize_review_role(role) == "primary" ? "Heavy Swimlane" : "Light Swimlane"
  end

  def review_role_short_label(role)
    Task.normalize_review_role(role) == "primary" ? "Heavy" : "Light"
  end

  def review_role_description(role)
    if Task.normalize_review_role(role) == "primary"
      "Full review pass: acceptance, design, tests, risk, findings, and merge readiness."
    else
      "Focused second pass: changed files, smoke path, docs, and handoff clarity."
    end
  end

  def review_status_classes(status)
    case status.to_s
    when "completed"
      "border-green-500/40 bg-green-500/10 text-green-700 dark:text-green-200"
    when "failed"
      "border-red-500/40 bg-red-500/10 text-red-700 dark:text-red-200"
    when "started"
      "border-primary/40 bg-primary/10 text-primary"
    else
      "border-subtle bg-surface text-secondary"
    end
  end

  def review_moment_complete?(events, moment)
    Array(events).any? { |event| event.review_moment == moment }
  end

  def review_lane_moment_timings(lane, live_at: Time.current)
    events_by_moment = latest_review_events_by_moment(lane.events)
    last_recorded_index = lane.moments.rindex { |moment| events_by_moment[moment].present? }
    next_live_index = last_recorded_index ? last_recorded_index + 1 : 0
    anchor_at = lane.started_at

    lane.moments.each_with_index.to_h do |moment, index|
      event = events_by_moment[moment]
      timing =
        if event
          seconds = review_elapsed_seconds(anchor_at, event.occurred_at)
          anchor_at = event.occurred_at.presence || anchor_at
          ReviewMomentTiming.new(event: event, seconds: seconds, status: "completed",
                                 anchor_at: anchor_at, occurred_at: event.occurred_at)
        elsif last_recorded_index && index < last_recorded_index
          ReviewMomentTiming.new(status: "skipped")
        elsif index == next_live_index && anchor_at.present?
          ReviewMomentTiming.new(seconds: review_elapsed_seconds(anchor_at, live_at), status: "live",
                                 anchor_at: anchor_at)
        else
          ReviewMomentTiming.new(status: "pending")
        end

      [moment, timing]
    end
  end

  def review_moment_duration_label(timing)
    case timing&.status
    when "completed"
      compact_stage_duration(timing.seconds) || "—"
    when "live"
      "Live #{compact_stage_duration(timing.seconds) || '<1m'}"
    when "skipped"
      "Not recorded"
    else
      "Pending"
    end
  end

  def review_moment_duration_classes(timing)
    case timing&.status
    when "completed"
      "border-green-500/40 bg-green-500/10 text-green-700 dark:text-green-200"
    when "live"
      "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-200"
    when "skipped"
      "border-subtle bg-surface text-muted"
    else
      "border-subtle bg-inset/60 text-muted"
    end
  end

  def review_moment_display_label(role, moment)
    label = Task.review_moment_label(role, moment)
    return label unless Task.normalize_review_role(role) == "primary"

    label.gsub("deep-review", "heavy-review").gsub("deep review", "heavy review")
  end

  def review_agent_name(reviewer)
    reviewer&.name.presence || "Unassigned"
  end

  def latest_review_reviewer_records(task)
    Array(task.task_events.chronological.reverse).each do |event|
      reviewers = Task.normalize_reviewers(event.metadata["reviewers"])
      return reviewers if reviewers.present?
    end
    []
  end

  def unresolved_review_agent(slug, role)
    return nil if slug.blank?

    StageAgentsHelper::StageAgent.new(
      stage: "reviewed",
      label: slug,
      weight: role,
      agent: nil
    )
  end

  def review_started_at_for(task, events)
    first_event_at = Array(events).filter_map(&:occurred_at).min
    intents = task.task_events.intents.where(to_stage: "reviewed").chronological.to_a
    return intents.last&.occurred_at if first_event_at.blank?

    intents.select { |intent| intent.occurred_at <= first_event_at }.last&.occurred_at
  end

  def latest_review_events_by_moment(events)
    Array(events).sort_by { |event| [event.occurred_at || Time.zone.at(0), event.id.to_i] }
                 .each_with_object({}) { |event, moments| moments[event.review_moment] = event }
  end

  def review_elapsed_seconds(from_time, to_time)
    return nil if from_time.blank? || to_time.blank?

    [(to_time - from_time).to_i, 0].max
  end
end
