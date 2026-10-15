# frozen_string_literal: true

# Markdown to HTML for the pages that render tracked Markdown: /docs
# (DocsController) and a dream's story on /dreams (DreamsHelper).
#
# Raw HTML is filtered (`filter_html`), and a link, autolink or image whose scheme is not
# on SAFE_SCHEMES renders as its literal Markdown text, never an <a href>. So
# `[x](javascript:alert(1))` shows as text instead of a clickable script.
#
# Why not Redcarpet's own `safe_links_only: true`: it also refuses every RELATIVE
# link (`[role](../agents/pokemon/role.md)`, `[x](#anchor)` passes but `role.md`
# does not), and the docs link to each other relatively all over. A link with no
# scheme is a path on this site, so it stays a link.
module SafeMarkdown
  SAFE_SCHEMES = %w[http https mailto].freeze

  # A URL scheme as a browser reads it: leading whitespace and control characters
  # dropped, tabs and newlines inside the scheme ignored (`java\nscript:` is
  # `javascript:`), case folded.
  SCHEME = /\A([a-z][a-z0-9+.\-]*):/i

  RENDER_OPTIONS = { hard_wrap: true, filter_html: true }.freeze
  MARKDOWN_OPTIONS = { fenced_code_blocks: true, tables: true, autolink: true,
                       strikethrough: true, no_intra_emphasis: true }.freeze

  module_function

  def render(markdown)
    Redcarpet::Markdown.new(Renderer.new(**RENDER_OPTIONS), **MARKDOWN_OPTIONS)
                       .render(markdown.to_s).html_safe # rubocop:disable Rails/OutputSafety
  end

  # True when a link target is a site path or carries a scheme on SAFE_SCHEMES.
  def safe_url?(url)
    scheme = url.to_s.gsub(/[\x00-\x20\x7F]/, "")[SCHEME, 1]
    scheme.nil? || SAFE_SCHEMES.include?(scheme.downcase)
  end

  # Redcarpet's HTML renderer with the link, autolink and image callbacks checked. Returning nil
  # from a callback makes Redcarpet emit the span's original Markdown as text.
  class Renderer < Redcarpet::Render::HTML
    include ERB::Util

    def link(url, title, content)
      return nil unless SafeMarkdown.safe_url?(url)

      title_attr = title.to_s.empty? ? "" : %( title="#{html_escape(title)}")
      %(<a href="#{html_escape(url)}"#{title_attr}>#{content}</a>)
    end

    def autolink(url, link_type)
      href = link_type == :email && !url.start_with?("mailto:") ? "mailto:#{url}" : url
      return nil unless SafeMarkdown.safe_url?(href)

      %(<a href="#{html_escape(href)}">#{html_escape(url)}</a>)
    end

    def image(url, title, alt_text)
      return nil unless SafeMarkdown.safe_url?(url)

      title_attr = title.to_s.empty? ? "" : %( title="#{html_escape(title)}")
      %(<img src="#{html_escape(url)}" alt="#{html_escape(alt_text)}"#{title_attr}>)
    end
  end
end
