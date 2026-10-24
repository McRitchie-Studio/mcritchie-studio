require "test_helper"

# [unit] admin-url-columns-use-http-href: a STORED or agent-written url reaches an
# href only through http_href / safe_link_to (ApplicationHelper). Brakeman does not
# read a plain ERB `<a href="<%= ... %>">`, so this guard is the tripwire for it.
#
# WHAT IT SCANS: every ERB output tag under app/views and app/components that is an
# href attribute value (`href="<%= ... %>"`) or that calls link_to / button_to or
# passes `href:`. Inside such a tag, every url-named expression (`*_url`, `.url`,
# `["url"]`, `[:url]`, `*_URL`) must be either:
#
#   - in a tag that goes through `safe_link_to` or `http_href(`, or
#   - a bare Rails route helper (`root_url`, `task_url`, ... read from the routes,
#     by name), or
#   - named in ALLOWED (anywhere) or SITE_ALLOWED (one file), each with the reason
#     it is SERVER-BUILT rather than stored.
#
# A url column read off a record (`@news.url`, `photo.page_url`) is never allowed
# by name: route it through safe_link_to instead.
class StoredUrlHrefGuardTest < ActiveSupport::TestCase
  ROOTS = %w[app/views app/components].freeze

  # Expressions that are server-built URLs wherever they appear.
  ALLOWED = {
    "build_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant or the tracked redirect, via broadcast_link",
    "cal_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant, via broadcast_link",
    "night_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant, via broadcast_link",
    "play_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant, via broadcast_link",
    "survey_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant, via broadcast_link",
    "survivor_url" => "broadcasts: Broadcast::TEMPLATE_LINKS constant, via broadcast_link",
    "toggle_url" => "agents activity filter: built by url_for over the current params",
    "remove_url" => "agents activity filter: built by url_for over the current params",
    "page_url" => "tasks stage pager: a lambda over url_for (photo.page_url is a different token)",
    "frame_url" => "alt videos: a signed storage URL minted from an object key",
    "version_url" => "alt videos: a signed storage URL minted from an object key",
    "intent_url" => "contents: a twitter.com/intent literal with url-encoded captions",
    "run_url" => "CI ladder: GitHub's own html_url for the workflow run",
    "ClientApps::StudioKit::STUDIO_URL" => "a constant",
    "STUDIO_URL" => "a constant",
    "message.reply_url" => "AgentMessage#reply_url composes a discord.com URL from ids",
    "@message.reply_url" => "AgentMessage#reply_url composes a discord.com URL from ids",
    "@message.discord_url" => "AgentMessage#discord_url composes a discord.com URL from ids",
    "delivery.url" => "ReportDelivery#url composes a discord.com URL from ids",
    "@last_delivery.url" => "ReportDelivery#url composes a discord.com URL from ids",
    "req.url" => "AppRequest#url composes https://<host>",
    "example.url" => "BuildGallery: config/build_gallery examples or AppRequest#url"
  }.freeze

  # Generic names allowed only in the one file where they are known server-built
  # (or are not an href at all).
  SITE_ALLOWED = {
    "app/components/task_card_component.html.erb" => {
      "local_url" => "only a presence test; the href is local_review_task_path",
      "url" => "part of local_url's presence test; the href is a route path",
      "pr_url" => "the CI meter's label, not an href"
    },
    "app/views/admin/dashboard/_quick_link.html.erb" => { "url" => "callers pass route helpers" },
    "app/views/broadcasts/_button.html.erb" => { "url" => "callers pass broadcast_link URLs from constants" },
    "app/views/contact_submissions/new.html.erb" => { "url" => "the link TEXT; the href is privacy_path" },
    "app/views/integrations/discord.html.erb" => { "[:url]" => "a constant setup-step table in the template" },
    "app/views/tasks/_release_phase_meter.html.erb" => { "[:url]" => "release_ci_run_url: GitHub's run URL" },
    "app/views/contents/_tiktok_assembly_card.html.erb" => { "mp4_url" => "a presence test; the button posts to a route path" }
  }.freeze

  TAG = /(href=["']?\s*)?<%(=|-)?(.*?)-?%>/m
  URL_TOKEN = /(?:[@\w.]|::)*(?:_url|\burl)\b|\[["']url["']\]|\[:url\]/i
  WRAPPED = /\bsafe_link_to\b|\bhttp_href\(/

  # Every [path, line, token, tag-code] a stored url could leak through.
  def self.violations(sources, route_helpers: route_helper_names)
    sources.flat_map do |path, src|
      src.to_enum(:scan, TAG).filter_map { Regexp.last_match }.flat_map do |m|
        pre, marker, code = m[1], m[2], m[3]
        next [] if marker.nil? && code.lstrip.start_with?("#") # <%# comment %>
        next [] unless pre || code.match?(/\b(link_to|button_to)\b|\bhref:/)
        next [] if code.match?(WRAPPED)

        line = src[0...m.begin(0)].count("\n") + 1
        code.scan(URL_TOKEN).uniq.reject { |tok| allowed?(path, tok, route_helpers) }.map { |tok| [ path, line, tok, code.strip ] }
      end
    end
  end

  def self.allowed?(path, tok, route_helpers)
    return true if tok.end_with?("_path")
    return true if ALLOWED.key?(tok) || SITE_ALLOWED.dig(path, tok)
    return true if route_helpers.include?(tok.delete_prefix("main_app."))

    false
  end

  def self.route_helper_names
    Rails.application.routes.named_routes.helper_names.map(&:to_s).to_set
  end

  def self.app_sources
    ROOTS.flat_map { |root| Dir.glob(Rails.root.join(root, "**/*.erb")) }.sort.to_h do |abs|
      [ Pathname(abs).relative_path_from(Rails.root).to_s, File.read(abs) ]
    end
  end

  test "no stored url reaches an href in app/views or app/components without http_href" do
    found = self.class.violations(self.class.app_sources)
    assert_empty found, <<~MSG
      These url expressions reach an href without http_href / safe_link_to:
      #{found.map { |path, line, tok, _| "  #{path}:#{line}  #{tok}" }.join("\n")}
      Use `safe_link_to name, url, ...` (or `http_href(url)`) for a stored or agent-written url.
      Only a SERVER-BUILT url may be added to ALLOWED / SITE_ALLOWED, with its reason.
    MSG
  end

  # The control: the scanner flags the shapes it exists to catch, and passes the
  # shapes it must not, on synthetic templates whose answer is known.
  test "control: the scanner flags a raw stored url and passes the wrapped and route forms" do
    routes = Set["news_url"]
    bad = {
      "app/views/x/raw.html.erb" => %(<a href="<%= @news.url %>">src</a>),
      "app/views/x/link.html.erb" => %(<%= link_to "View", @news.x_post_url, target: "_blank" %>),
      "app/views/x/multi.html.erb" => %(<%= link_to "Watch",\n      video.source_url, class: "a" %>),
      "app/views/x/block.html.erb" => %(<%= link_to sheet.image_url, target: "_blank" do %>img<% end %>),
      "app/views/x/json.html.erb" => %(<%= link_to "reply", event.detail["url"] %>),
      "app/views/x/attr.html.erb" => %(<% opts.merge!(href: rel.qa_url) %>)
    }
    flagged = self.class.violations(bad, route_helpers: routes).map(&:first).uniq
    assert_equal bad.keys.sort, flagged.sort, "every raw shape must be flagged"

    good = {
      "app/views/x/safe.html.erb" => %(<%= safe_link_to "View", @news.x_post_url, target: "_blank" %>),
      "app/views/x/href.html.erb" => %(<% if (h = http_href(@news.url)) %><a href="<%= h %>">x</a><% end %>),
      "app/views/x/route.html.erb" => %(<%= link_to "News", news_url(@news) %> <%= link_to "Path", news_path(@news) %>),
      "app/views/x/img.html.erb" => %(<img src="<%= @news.image_url %>">),
      "app/views/x/comment.html.erb" => %(<%# link_to "x", @news.url %>)
    }
    assert_empty self.class.violations(good, route_helpers: routes)
  end

  test "control: a route helper name is allowed only bare, never off a record" do
    routes = Set["page_url"]
    src = { "app/views/x/r.html.erb" => %(<%= link_to "p", photo.page_url %>) }
    assert_equal [ "photo.page_url" ], self.class.violations(src, route_helpers: routes).map { |row| row[2] }
  end

  # An exemption is a claim about a site; when the site is gone, so is the claim.
  test "every SITE_ALLOWED entry still names a token present in its file" do
    SITE_ALLOWED.each do |path, names|
      src = File.read(Rails.root.join(path))
      names.each_key do |tok|
        lead = tok.start_with?("[") ? "" : "(?<![\\w.])"
        assert src.match?(/#{lead}#{Regexp.escape(tok)}(?!\w)/), "#{path} no longer carries #{tok}; drop the exemption"
      end
    end
  end
end
