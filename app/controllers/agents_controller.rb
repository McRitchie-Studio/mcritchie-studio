class AgentsController < ApplicationController
  skip_before_action :require_authentication

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
  end

  private

  def agent_docs_by_slug(slugs)
    slugs.to_h do |slug|
      [slug, agent_docs_for(slug)]
    end
  end

  def agent_docs_for(slug)
    doc_slug = [slug, slug.tr("-", "_")].uniq.find do |candidate|
      Rails.root.join("docs", "agents", "agents", candidate).directory?
    end
    return [] unless doc_slug

    dir = Rails.root.join("docs", "agents", "agents", doc_slug)
    return [] unless dir.directory?

    preferred = { "HEARTBEAT" => 0, "soul" => 1, "role" => 2 }
    Dir.glob(dir.join("*.md")).sort_by do |file|
      basename = File.basename(file, ".md")
      [preferred.fetch(basename, 99), basename.downcase]
    end.map do |file|
      filename = File.basename(file)
      {
        label: filename,
        path: "agents/#{doc_slug}/#{filename}"
      }
    end
  end
end
