module ReviewEventsHelper
  ReviewLane = Struct.new(:role, :label, :description, :agent, :events, :moments, keyword_init: true)

  def review_event_lanes(task, agents, events)
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
        moments: Task::REVIEW_MOMENTS.fetch(role)
      )
    end
  end

  def review_role_label(role)
    role.to_s == "primary" ? "Primary Review" : "Light Review"
  end

  def review_role_description(role)
    if role.to_s == "primary"
      "Deep review owner: acceptance, design, tests, risk, and merge readiness."
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
