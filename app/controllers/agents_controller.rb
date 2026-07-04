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
    @agent_doc_tree = agent_doc_tree_for(@agent.slug)
  end

  private

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
