require "test_helper"

# [unit] image-tag-stored-url-500: a STORED or agent-written url reaches an image or
# video src only through safe_image_src / safe_image_tag (ApplicationHelper). The
# sibling of stored_url_href_guard_test.rb, for the src forms. Two harms it guards:
# image_tag / video_tag read a non-URL string as an asset FILE NAME and the asset
# pipeline raises (a 500 for the whole page), and a raw src renders whatever scheme
# a column holds.
#
# WHAT IT SCANS: every ERB output tag under app/views and app/components that is a
# `src=` or `poster=` attribute value (not `data-src=`, not Alpine's `:src=`, not a
# JS `this.src=`), or that calls image_tag / video_tag / audio_tag / tag.img /
# tag.video / tag.source / tag.audio. For an attribute, every url-named expression
# (`*_url`, `.url`, `["url"]`, `*_uri`) is judged; with none, the expression is
# judged whole (a local can carry a url). For a call, its first argument is judged
# the same way. Each must be either:
#
#   - in a tag that goes through `safe_image_src(` or `safe_image_tag`, or
#   - a path helper (`asset_path(...)`, `brand_kit_original_path(...)`, `x.path(...)`)
#     or a bare Rails route helper, or
#   - named in ALLOWED (anywhere) or SITE_ALLOWED (one file), each with the reason
#     it is SERVER-BUILT rather than stored.
class StoredUrlSrcGuardTest < ActiveSupport::TestCase
  ROOTS = %w[app/views app/components].freeze

  ALLOWED = {
    "frame_url" => "alt videos: a signed storage URL minted from an object key",
    "audio_url" => "alt videos: a signed storage URL minted from the source object key",
    "@open_pixel_url" => "broadcast mailer: the tracking route the mailer builds",
    "@email_asset_host" => "broadcast email views: the mailer's asset host plus a fixed file name",
    "identity.mark_light_uri" => "client kit: Mark.data_uri over the kit's own SVG",
    "identity.mark_dark_uri" => "client kit: Mark.data_uri over the kit's own SVG"
  }.freeze

  SITE_ALLOWED = {
    "app/views/layouts/broadcast_email.html.erb" => {
      "yield :email_hero_image" => "broadcasts/_email_head: @email_asset_host plus a fixed hero file"
    },
    "app/views/stack/index.html.erb" => {
      "sample" => "a static asset name from the stack's icon table", "plain" => "a static asset name",
      "icon" => "a static asset name from the stack's icon table"
    },
    "app/views/stack/matrix.html.erb" => {
      "sample" => "a static asset name", "tile" => "a static asset name", "chest" => "a static asset name"
    },
    "app/views/credential_vaults/index.html.erb" => {
      "icon" => "a static asset name from the vault icon table", "tile" => "a static asset name"
    },
    "app/views/packages/_brand.html.erb" => { "mark" => "a static asset name for the brand mark" },
    "app/views/build/_gallery_card.html.erb" => { "example.image" => "config/build_gallery: a static asset name" },
    "app/views/applications/_cto_avatar.html.erb" => { "src" => "assigned from image_path(row.portrait_asset), a static asset" },
    "app/views/shared/_auth_card.html.erb" => { "\"/brand/icon-light.svg\"" => "a literal" }
  }.freeze

  TAG = /((?<![\w.:-])(?:src|poster)=["']?\s*)?<%(=|-)?(.*?)-?%>/m
  CALL = /\b(?:image_tag|video_tag|audio_tag|tag\.(?:img|video|source|audio))\b/
  URL_TOKEN = /(?:[@\w.]|::)*(?:_url|\burl|_uri)\b|\[["']url["']\]|\[:url\]/i
  WRAPPED = /\bsafe_image_src\(|\bsafe_image_tag\b/

  def self.violations(sources, route_helpers: route_helper_names)
    sources.flat_map do |path, src|
      src.to_enum(:scan, TAG).filter_map { Regexp.last_match }.flat_map do |m|
        pre, marker, code = m[1], m[2], m[3]
        next [] if marker.nil? && code.lstrip.start_with?("#") # <%# comment %>
        next [] if code.match?(WRAPPED)

        expr = pre ? code.strip : first_argument(code)
        next [] if expr.nil?

        line = src[0...m.begin(0)].count("\n") + 1
        tokens = expr.scan(URL_TOKEN).uniq
        tokens = [ expr ] if tokens.empty?
        tokens.reject { |tok| allowed?(path, tok, route_helpers) }.map { |tok| [ path, line, tok, code.strip ] }
      end
    end
  end

  # The first argument of an image_tag-style call, or nil when the tag makes none.
  def self.first_argument(code)
    call = code.match(CALL) or return nil
    rest = code[call.end(0)..].sub(/\A\s*\(?\s*/, "")
    rest = rest.sub(/\Asrc:\s*/, "") if call[0].start_with?("tag.")
    depth = 0
    rest.each_char.with_index do |char, i|
      depth += 1 if "([{".include?(char)
      depth -= 1 if ")]}".include?(char)
      return rest[0...i].strip if depth.negative? || (depth.zero? && char == ",")
    end
    rest.sub(/\s+(?:if|unless)\s.*\z/m, "").strip
  end

  def self.allowed?(path, tok, route_helpers)
    return true if tok.end_with?("_path") || tok.match?(/\A[\w:]+\.path\(|\A\w+_path\(/)
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

  test "no stored url reaches an image or video src without safe_image_src" do
    found = self.class.violations(self.class.app_sources)
    assert_empty found, <<~MSG
      These expressions reach an image/video src without safe_image_src / safe_image_tag:
      #{found.map { |path, line, tok, _| "  #{path}:#{line}  #{tok}" }.join("\n")}
      Use `safe_image_tag url, ...` (or `src="<%= safe_image_src(url) %>"`) for a stored or agent-written url.
      Only a SERVER-BUILT value may be added to ALLOWED / SITE_ALLOWED, with its reason.
    MSG
  end

  # The control: the scanner flags the shapes it exists to catch, and passes the
  # shapes it must not, on synthetic templates whose answer is known.
  test "control: the scanner flags a raw stored src and passes the wrapped and path forms" do
    routes = Set["news_url"]
    bad = {
      "app/views/x/tag.html.erb" => %(<%= image_tag archetype.image_url, alt: "a" %>),
      "app/views/x/paren.html.erb" => %(<%= image_tag(artifact.image_url, class: "w") %>),
      "app/views/x/local.html.erb" => %(<%= image_tag avatar, class: "w" %>),
      "app/views/x/multi.html.erb" => %(<%= image_tag photo.display_url,\n      alt: "u" %>),
      "app/views/x/raw.html.erb" => %(<img src="<%= @news.article_image_url %>">),
      "app/views/x/rawlocal.html.erb" => %(<img src="<%= headshot %>" alt="">),
      "app/views/x/video.html.erb" => %(<video src="<%= content.final_video_url %>"></video>),
      "app/views/x/json.html.erb" => %(<img src="<%= asset["image_url"] %>">),
      "app/views/x/tagimg.html.erb" => %(<%= tag.img src: person.avatar_url %>),
      "app/views/x/poster.html.erb" => %(<video poster="<%= clip.poster_url %>"></video>)
    }
    flagged = self.class.violations(bad, route_helpers: routes).map(&:first).uniq
    assert_equal bad.keys.sort, flagged.sort, "every raw shape must be flagged"

    good = {
      "app/views/x/safe.html.erb" => %(<%= safe_image_tag archetype.image_url, alt: "a" %>),
      "app/views/x/src.html.erb" => %(<img src="<%= safe_image_src(@news.article_image_url) %>">),
      "app/views/x/asset.html.erb" => %(<video src="<%= asset_path(example.motion) %>"></video>),
      "app/views/x/route.html.erb" => %(<iframe src="<%= preview_broadcast_path(@b) %>"></iframe> <img src="<%= news_url(@n) %>">),
      "app/views/x/data.html.erb" => %(<div data-src="<%= url %>"></div> <img :src="<%= look %>.image_url">),
      "app/views/x/js.html.erb" => %(<img src="<%= safe_image_src(a) %>" onerror="this.src='<%= b.sprite_url %>'">),
      "app/views/x/href.html.erb" => %(<%= link_to "x", @news.url %>),
      "app/views/x/comment.html.erb" => %(<%# image_tag @news.image_url %>)
    }
    assert_empty self.class.violations(good, route_helpers: routes)
  end

  # An exemption is a claim about a site; when the site is gone, so is the claim.
  test "every SITE_ALLOWED entry still names a token present in its file" do
    SITE_ALLOWED.each do |path, names|
      src = File.read(Rails.root.join(path))
      names.each_key do |tok|
        assert src.include?(tok), "#{path} no longer carries #{tok}; drop the exemption"
      end
    end
  end
end
