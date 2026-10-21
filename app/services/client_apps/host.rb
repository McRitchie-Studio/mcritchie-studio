# frozen_string_literal: true

module ClientApps
  # The shared client-app host's answer to one request for <sub>.<preview domain>
  # (docs/agents/system/client-app-host.md). Called by the ClientAppHost
  # middleware, in front of the hub's cookies, session and routes, so it is a bare
  # Rack response: no controller, no layout, no cookie.
  #
  #   live bundle        the file the path names, from the app's current version
  #                      (App#preview_version); `/` and a directory are its
  #                      index.html; an unknown path WITHOUT an extension is the
  #                      SPA fallback, index.html; an unknown file is a 404
  #   no bundle yet      the themed "being built" page, for a client app (an App
  #                      with a CTO) or a held /build request
  #   anything else      a bare 404 that names nothing of the hub's
  #
  # Every HTML page of a bundle is served wrapped in the Studio template (the
  # navbar, the theme and the footer: StudioKit), and /_studio/kit/<version>/
  # serves the one shared kit those pages load, on every app.
  class Host
    METHODS = %w[GET HEAD].freeze

    # The bundle's own policy: its files only. Inline styles are allowed (model
    # output leans on style attributes); inline script is not, so a bundle's
    # script lives in a .js file. connect-src 'self' is this sub only, never the
    # hub, and nothing may frame it.
    BUNDLE_CSP = [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "font-src 'self' data:",
      "connect-src 'self'",
      "media-src 'self'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'self'",
      "frame-src 'none'",
      "frame-ancestors 'none'",
      "worker-src 'self'",
      "manifest-src 'self'"
    ].join("; ").freeze

    # The host's own pages (being built, 404, errors): no script at all.
    PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; " \
               "form-action 'none'; frame-ancestors 'none'"

    SECURITY_HEADERS = {
      "x-content-type-options" => "nosniff",
      "referrer-policy" => "no-referrer",
      "x-frame-options" => "DENY",
      "cross-origin-opener-policy" => "same-origin",
      "cross-origin-resource-policy" => "same-origin",
      "permissions-policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    }.freeze

    # HTML must revalidate so a publish shows at once (the ETag makes that a 304);
    # a file whose name carries a content hash (app-3f9a2c1b.js) is immutable;
    # anything else may be reused for five minutes.
    HTML_CACHE = "no-cache"
    HASHED_CACHE = "public, max-age=31536000, immutable"
    ASSET_CACHE = "public, max-age=300"
    HASHED_NAME = /[.-][0-9a-f]{8,}\.[a-z0-9]+\z/i

    # A failure (storage down, a corrupt object) answers the host's own 500 page,
    # never a hub error page, and is recorded as the hub records its own: an
    # ErrorLog naming the sub, and Sentry.
    def self.call(env, sub)
      new(env, sub).response
    rescue StandardError => e
      Rails.logger.error("[client-app-host] #{sub}: #{e.class}: #{e.message}")
      record_failure(e, sub)
      page(500, Pages.error)
    end

    def self.record_failure(exception, sub)
      Sentry.capture_exception(exception) if defined?(Sentry) && Sentry.respond_to?(:capture_exception)
      log = ErrorLog.capture!(exception)
      log.update(target_name: sub) if sub && log.respond_to?(:target_name=)
    rescue StandardError => e
      Rails.logger.error("[client-app-host] could not record the failure: #{e.class}")
    end

    def self.page(status, html, head: false)
      headers = SECURITY_HEADERS.merge("content-type" => "text/html; charset=utf-8",
                                       "content-security-policy" => PAGE_CSP, "cache-control" => "no-store",
                                       "content-length" => html.bytesize.to_s)
      [ status, headers, head ? [] : [ html ] ]
    end

    def initialize(env, sub)
      @env = env
      @sub = sub
      @head = env["REQUEST_METHOD"] == "HEAD"
    end

    def response
      return method_not_allowed unless METHODS.include?(@env["REQUEST_METHOD"])
      return not_found if @sub.nil? || AppRequest.reserved_names.include?(@sub)

      app = App.find_by(slug: @sub)
      version = app&.current_preview
      return kit_asset(app, version) if kit_path?
      return serve(app, version) if version

      site = BeingBuilt.for(@sub, app)
      site ? self.class.page(200, Pages.being_built(site), head: @head) : not_found
    end

    private

    def serve(app, version)
      path = resolve(version)
      return not_found unless path

      entry = version.entry(path)
      return serve_page(app, version, path, entry) if page?(entry)

      etag = %("#{entry.fetch('sha256')}")
      headers = bundle_headers(entry.fetch("content_type"), cache_control(path), etag)
      return [ 304, headers, [] ] if fresh?(etag)

      headers["content-length"] = entry.fetch("size").to_s
      return [ 200, headers, [] ] if @head

      [ 200, headers, [ BundleStore.read(version.key_for(path), sha256: entry.fetch("sha256")) ] ]
    end

    # An HTML page wears the Studio template (StudioKit): the shell is placed
    # at serve time, so a kit or engine change reaches every app on its next
    # request. The ETag covers the page's bytes AND the shell, so a new kit
    # or a renamed app is a new ETag.
    def serve_page(app, version, path, entry)
      shell = StudioKit.shell_for(app)
      etag = %("#{entry.fetch('sha256')[0, 32]}-#{shell.digest}")
      headers = bundle_headers(entry.fetch("content_type"), HTML_CACHE, etag)
      return [ 304, headers, [] ] if fresh?(etag)

      html = StudioKit.wrap(BundleStore.read(version.key_for(path), sha256: entry.fetch("sha256")), shell)
      headers["content-length"] = html.bytesize.to_s
      [ 200, headers, @head ? [] : [ html ] ]
    end

    def page?(entry) = entry.fetch("content_type").to_s.start_with?("text/html")

    # The shared kit (StudioKit.assets), on every app that answers at all: an
    # app with a bundle, or one being built. Its URL carries its version, so the
    # current one is cached for a year.
    def kit_asset(app, version)
      return not_found unless version || BeingBuilt.for(@sub, app)

      found = StudioKit.asset_for(@env["PATH_INFO"])
      return not_found unless found

      bytes, type, current = found
      etag = %("#{Digest::SHA256.hexdigest(bytes)[0, 32]}")
      headers = bundle_headers(type, current ? HASHED_CACHE : ASSET_CACHE, etag)
      return [ 304, headers, [] ] if fresh?(etag)

      headers["content-length"] = bytes.bytesize.to_s
      [ 200, headers, @head ? [] : [ bytes ] ]
    end

    def kit_path? = @env["PATH_INFO"].to_s.start_with?(StudioKit::PATH_PREFIX)

    def bundle_headers(type, cache, etag)
      SECURITY_HEADERS.merge("content-type" => type, "content-security-policy" => BUNDLE_CSP,
                             "cache-control" => cache, "etag" => etag)
    end

    # The manifest path this request is for, or nil for a 404.
    def resolve(version)
      raw = Rack::Utils.unescape_path(@env["PATH_INFO"].to_s)
      return nil unless raw.valid_encoding?

      path = raw.delete_prefix("/")
      return nil if path.split("/").any? { |segment| segment == ".." || segment.start_with?(".") }

      candidates = if path.empty? || path.end_with?("/") then [ "#{path}#{ClientAppBundle::INDEX}" ]
                   else [ path, "#{path}/#{ClientAppBundle::INDEX}", "#{path}.html" ]
                   end
      found = candidates.find { |candidate| version.entry(candidate) }
      return found if found

      # The SPA fallback: a client-side route (no extension) is the app's index.
      ClientAppBundle.extension(path).empty? ? ClientAppBundle::INDEX : nil
    end

    def cache_control(path)
      return HTML_CACHE if path.end_with?(".html")

      path.match?(HASHED_NAME) ? HASHED_CACHE : ASSET_CACHE
    end

    def fresh?(etag)
      sent = @env["HTTP_IF_NONE_MATCH"].to_s
      sent.split(",").map { |tag| tag.strip.delete_prefix("W/") }.include?(etag)
    end

    def not_found = self.class.page(404, Pages.not_found, head: @head)

    def method_not_allowed
      status, headers, body = self.class.page(405, Pages.not_found)
      [ status, headers.merge("allow" => METHODS.join(", ")), body ]
    end
  end
end
