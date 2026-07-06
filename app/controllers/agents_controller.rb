class AgentsController < ApplicationController
  skip_before_action :require_authentication

  # The shared activity-feed read layer (session lists, pokemon/soul/grade/transition
  # bulk lookups) — the same queries the /alex/heartbeat surface uses.
  include ActivityFeed

  # Page size for the cross-session activity feed, matched to the heartbeat's.
  ACTIVITIES_PER_PAGE = 25

  # The reimagined cross-session activity feed — every narrated AgentActivity across
  # all sessions, newest-first, with its drilled-down raw actions (also newest-first)
  # and inline Alex/McRitchie grade cells on BOTH. An optional ?sessions= (comma list
  # or array) narrows to a multi-select of Pokémon sessions (blank = every session);
  # @session_filters feeds the slide-in filter sidebar. Read-only — grading POSTs to
  # the existing heartbeat grade endpoints.
  def activities
    @session_ids = parse_session_ids(params[:sessions])
    @page  = [params[:page].to_i, 1].max

    scope  = AgentActivity.order(opened_at: :desc, seq: :desc, id: :desc)
    scope  = scope.where(session_id: @session_ids) if @session_ids.any?
    @total = scope.count
    @activities = scope.offset((@page - 1) * ACTIVITIES_PER_PAGE).limit(ACTIVITIES_PER_PAGE).to_a

    # Drill-down actions, DISPLAYED newest-first under each activity (the operator's
    # sort). One query, grouped in Ruby, so the whole page adds no per-row query.
    actions_by_activity = AgentAction.where(agent_activity_id: @activities.map(&:id))
                                     .order(occurred_at: :desc, seq: :desc, id: :desc)
                                     .to_a.group_by(&:agent_activity_id)
    @activity_rows = @activities.map { |activity| [activity, actions_by_activity[activity.id] || []] }
    page_actions = actions_by_activity.values.flatten

    # The shared-turn fade marks the 2nd+ tool-call of each metered turn; it is defined
    # by CHRONOLOGICAL first-seen, so compute it on a chronological pass even though the
    # rows RENDER newest-first.
    chronological = page_actions.sort_by { |a| [a.occurred_at || Time.at(0), a.seq.to_i, a.id] }
    @shared_turn_ids = helpers.heartbeat_shared_turn_ids(chronological)

    @session_filters = session_filter_options(@session_ids)
    @pokemon_by_slug = pokemon_lookup(page_actions, @activities)
    @agents_by_slug  = agent_soul_lookup(@activities)
    @activity_grades = activity_grade_lookup(@activities)
    @action_grades   = action_grade_lookup(page_actions)
    @stage_transitions = stage_transitions_for(@activities)
    @has_prev = @page > 1
    @has_next = @page * ACTIVITIES_PER_PAGE < @total
  end

  def index
    @agents = Agent.includes(:tasks).order(:position)
    @agent_docs_by_slug = agent_docs_by_slug(@agents.map(&:slug))
  end

  def show
    @agent = Agent.find_by(slug: params[:slug])
    return redirect_to agents_path, alert: "Agent not found" unless @agent
    @tasks = @agent.tasks.recent.limit(20)
    @activities = @agent.activities.recent.limit(20)
    @skills = @agent.skills
    @agent_doc_tree = agent_doc_tree_for(@agent.slug)
  end

  private

  # Normalise the ?sessions= filter into a clean, de-duped id list. Accepts either a
  # comma-joined string ("a,b") or a Rails array param (sessions[]=a&sessions[]=b),
  # so both the sidebar's URL writes and a hand-typed link work.
  def parse_session_ids(raw)
    Array(raw).flat_map { |value| value.to_s.split(",") }
              .map(&:strip).reject(&:blank?).uniq
  end

  def agent_docs_by_slug(slugs)
    slugs.to_h do |slug|
      [slug, agent_docs_for(slug)]
    end
  end

  def agent_docs_for(slug)
    doc_slug = agent_doc_slug(slug)
    return [] unless doc_slug

    dir = Rails.root.join("docs", "agents", "agents", doc_slug)
    return [] unless dir.directory?

    preferred = { "HEARTBEAT.md" => 0, "soul.md" => 1, "role.md" => 2 }
    Dir.glob(dir.join("**", "*.md")).sort_by do |file|
      relative = Pathname(file).relative_path_from(dir).to_s
      [preferred.fetch(relative, 99), relative.downcase]
    end.map do |file|
      relative = Pathname(file).relative_path_from(dir).to_s
      {
        label: File.basename(file),
        path: "agents/#{doc_slug}/#{relative}"
      }
    end
  end

  def agent_doc_tree_for(slug)
    doc_slug = agent_doc_slug(slug)
    return [] unless doc_slug

    dir = Rails.root.join("docs", "agents", "agents", doc_slug)
    Dir.glob(dir.join("**", "*")).sort_by do |path|
      relative = Pathname(path).relative_path_from(dir).to_s
      [relative.split("/"), File.directory?(path) ? 0 : 1]
    end.map do |path|
      relative = Pathname(path).relative_path_from(dir).to_s
      markdown = File.file?(path) && File.extname(path) == ".md"
      {
        name: File.basename(path),
        path: relative,
        depth: relative.count("/"),
        directory: File.directory?(path),
        markdown: markdown,
        doc_path: markdown ? "agents/#{doc_slug}/#{relative}" : nil
      }
    end
  end

  def agent_doc_slug(slug)
    [slug, slug.tr("-", "_")].uniq.find do |candidate|
      Rails.root.join("docs", "agents", "agents", candidate).directory?
    end
  end
end
