class DocsController < ApplicationController
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
    @title, @content = lift_title(render_markdown(File.read(full_path)), fallback: File.basename(path).titleize)
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

  # The page header holds the page's one h1 (studio/_page_header), so the doc's own first
  # h1 becomes the header's title and leaves the body; any later h1 drops to an h2. A doc
  # with no h1 keeps its body whole, under its file name as the title.
  def lift_title(html, fallback:)
    fragment = Nokogiri::HTML5::DocumentFragment.parse(html.to_s)
    headings = fragment.css("h1")
    return [ fallback, html ] if headings.empty?

    title = headings.first.text.strip.presence || fallback
    headings.first.remove
    headings.drop(1).each { |heading| heading.name = "h2" }
    # The fragment is SafeMarkdown's own output, re-serialized: no new markup enters it.
    [ title, fragment.to_html.html_safe ] # rubocop:disable Rails/OutputSafety
  end

  # SafeMarkdown: raw HTML filtered, and a javascript: or other unsafe link left as text.
  def render_markdown(text)
    SafeMarkdown.render(text)
  end
end
