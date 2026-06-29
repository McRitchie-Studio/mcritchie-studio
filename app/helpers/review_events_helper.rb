module ReviewEventsHelper
  ReviewLane = Struct.new(:role, :label, :description, :agent, :events, :moments, :top_agents, keyword_init: true)

  def review_event_lanes(task, agents, events, process: nil)
    process ||= ReviewProcessHub.new(agents: agents)
    by_role = Array(events).group_by(&:review_role)
    by_slug = agents.index_by(&:slug)
    reviewers = latest_review_reviewer_records(task)

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
        top_agents: process.top_agents(role)
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
        top_agents: process.top_agents(role)
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

  def review_moment_display_label(role, moment)
    label = Task.review_moment_label(role, moment)
    return label unless Task.normalize_review_role(role) == "primary"

    label.gsub("deep-review", "heavy-review").gsub("deep review", "heavy review")
  end

  def review_agent_name(reviewer)
    reviewer&.name.presence || "Unassigned"
  end

  def review_agent_avatar_record(reviewer)
    reviewer&.agent || reviewer
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
end
