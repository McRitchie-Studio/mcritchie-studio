class DocsController < ApplicationController
  skip_before_action :require_authentication

  DOCS_ROOT = Rails.root.join("docs", "agents")

  def index
    @system_docs = list_docs("system")
    @shared_docs = list_docs("shared")
    @agent_docs = Dir.children(DOCS_ROOT.join("agents")).sort.map do |agent_name|
      { name: agent_name, docs: list_docs("agents/#{agent_name}") }
    end
  end

  def show
    raw_path = params[:format].present? ? "#{params[:path]}.#{params[:format]}" : params[:path].to_s
    path = raw_path.delete_suffix(".md")
    request.format = :html if raw_path.end_with?(".md")

    if path.include?("..") || !path.match?(/\A[a-z0-9_\-\/]+\z/i)
      raise ActiveRecord::RecordNotFound
    end

    full_path = DOCS_ROOT.join("#{path}.md")

    unless full_path.to_s.start_with?(DOCS_ROOT.to_s) && File.exist?(full_path)
      raise ActiveRecord::RecordNotFound
    end

    @path = path
    @title = File.basename(path).titleize
    @content = render_markdown(File.read(full_path))
    render :show, formats: [:html]
  end

  private

  def list_docs(subdir)
    dir = DOCS_ROOT.join(subdir)
    return [] unless dir.exist?

    Dir.glob(dir.join("*.md")).sort.map do |file|
      name = File.basename(file, ".md")
      { name: name, path: "#{subdir}/#{name}" }
    end
  end

  def render_markdown(text)
    renderer = Redcarpet::Render::HTML.new(hard_wrap: true, filter_html: true)
    markdown = Redcarpet::Markdown.new(renderer,
      fenced_code_blocks: true,
      tables: true,
      autolink: true,
      strikethrough: true,
      no_intra_emphasis: true
    )
    markdown.render(text).html_safe
  end
end
