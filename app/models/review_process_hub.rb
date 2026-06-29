require "set"

class ReviewProcessHub
  PIPELINE_STAGES = %w[submitted reviewed assembled shipped].freeze

  AgentStat = Struct.new(:slug, :name, :count, :agent, keyword_init: true)
  Reviewer = Struct.new(:slug, :name, :agent, keyword_init: true)
  TaskSnapshot = Struct.new(:task, :reviewers, :review_event_count, :latest_review_at, keyword_init: true) do
    def reviewer_for(role)
      reviewers[Task.normalize_review_role(role)]
    end
  end

  def initialize(agents: Agent.order(:position).to_a, task_scope: Task.all, event_scope: TaskEvent.all)
    @agents = Array(agents)
    @task_scope = task_scope
    @event_scope = event_scope
  end

  def top_agents(role, limit: 3)
    role = Task.normalize_review_role(role)
    agent_counts.fetch(role, {}).sort_by { |slug, count| [-count, agent_name(slug)] }
                .first(limit)
                .map { |slug, count| AgentStat.new(slug: slug, name: agent_name(slug), count: count, agent: agent_for(slug)) }
  end

  def pipeline_tasks(limit: 4)
    PIPELINE_STAGES.index_with do |stage|
      @task_scope.where(stage: stage).includes(:task_events).ordered.limit(limit).map { |task| snapshot_for(task) }
    end
  end

  def snapshot_for(task)
    events = task.task_events.to_a.sort_by { |event| [event.occurred_at || Time.zone.at(0), event.id.to_i] }
    review_events = events.select(&:review_check_in?)
    TaskSnapshot.new(
      task: task,
      reviewers: reviewers_from(events),
      review_event_count: review_events.size,
      latest_review_at: review_events.last&.occurred_at
    )
  end

  private

  def agent_counts
    @agent_counts ||= begin
      buckets = Hash.new { |roles, role| roles[role] = Hash.new { |slugs, slug| slugs[slug] = Set.new } }
      @event_scope.where(kind: [TaskEvent::INTENT, TaskEvent::CHECKPOINT]).find_each do |event|
        add_reviewer_assignments(buckets, event)
        add_check_in_actor(buckets, event)
      end
      buckets.transform_values { |slugs| slugs.transform_values(&:size) }
    end
  end

  def add_reviewer_assignments(buckets, event)
    return unless event.intent? && event.to_stage == "reviewed"

    Task.normalize_reviewers(event.metadata["reviewers"]).each do |reviewer|
      role = Task.normalize_review_role(reviewer["weight"])
      slug = normalize_actor_slug(reviewer["slug"])
      next if role.blank? || slug.blank?

      buckets[role][slug] << event.task_slug
    end
  end

  def add_check_in_actor(buckets, event)
    return unless event.review_check_in?

    role = event.review_role
    slug = normalize_actor_slug(event.actor)
    return if role.blank? || slug.blank?

    buckets[role][slug] << event.task_slug
  end

  def reviewers_from(events)
    reviewers = {}

    events.reverse_each do |event|
      Task.normalize_reviewers(event.metadata["reviewers"]).each do |entry|
        role = Task.normalize_review_role(entry["weight"])
        slug = normalize_actor_slug(entry["slug"])
        reviewers[role] ||= reviewer_for(slug) if role.present? && slug.present?
      end
      break if reviewers.keys.sort == Task::REVIEW_ROLES.sort
    end

    events.reverse_each do |event|
      next unless event.review_check_in?

      role = event.review_role
      slug = normalize_actor_slug(event.actor)
      reviewers[role] ||= reviewer_for(slug) if role.present? && slug.present?
    end

    reviewers
  end

  def reviewer_for(slug)
    Reviewer.new(slug: slug, name: agent_name(slug), agent: agent_for(slug))
  end

  def normalize_actor_slug(value)
    value.to_s.strip.downcase.split("@").first.presence
  end

  def agent_for(slug)
    agents_by_slug[slug.to_s]
  end

  def agent_name(slug)
    agent_for(slug)&.name.presence || slug.to_s.tr("_-", " ").presence&.titleize || "Unknown"
  end

  def agents_by_slug
    @agents_by_slug ||= @agents.index_by(&:slug)
  end
end
