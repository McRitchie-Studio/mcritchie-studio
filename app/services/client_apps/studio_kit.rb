# frozen_string_literal: true

module ClientApps
  # THE STUDIO TEMPLATE for client apps (docs/agents/system/client-app-host.md,
  # "The Studio template"). Every app the shared host serves wears the Studio
  # navbar (the app's name and mark, a theme toggle, a menu) and the engine's
  # site footer ("Built with McRitchie Studio"), in the app's own palette, light
  # and dark. Alex McRitchie, 2026-10-20: "We want to build all the apps to a standard and
  # that should start with a template and have a continuity."
  #
  # So nothing of the shell is copied into a bundle, where it would freeze and
  # drift. The host owns it:
  #
  #   assets     ONE shared kit, served on every app host at
  #              /_studio/kit/<version>/studio-kit.css and studio-kit.js
  #              (same origin, so the bundle CSP's 'self' covers it; a year,
  #              immutable, since the version is the content's digest).
  #   wrap       every HTML page the host serves is wrapped AT SERVE TIME: the
  #              kit's <link>, the app's theme and the kit's <script> go into its
  #              <head>, the navbar after <body>, the footer before </body>. A
  #              change to the engine or to this template reaches every app on its
  #              next request, with no rebuild.
  #
  # Engine-derived, never hand-copied:
  #   - the CSS is the engine's own (engine.css: the button and card utilities
  #     and the navbar's nav-shell band table), compiled by the hub's Tailwind
  #     against only the kit's templates (Css), plus the site footer's scoped CSS
  #     lifted out of the engine's studio/site_footer/_assets partial;
  #   - the footer is the engine's studio/site_footer/_footer partial, rendered
  #     with facts for the app (Studio::SiteFooter.resolve);
  #   - the theme is Studio::ThemeResolver's full token set (page, surfaces,
  #     the AA-derived inks, the primary scale), once per side of the app's
  #     palette;
  #   - the toggle is the engine's components/_theme_toggle partial with its
  #     Alpine bindings rewritten to the kit's data hooks (kit_toggle).
  module StudioKit
    STUDIO_URL = "https://mcritchie.studio"
    PATH_PREFIX = "/_studio/kit/"
    CSS_FILE = "studio-kit.css"
    JS_FILE = "studio-kit.js"
    ASSET_DIR = Rails.root.join("app/assets/studio_kit")
    CONTENT_TYPES = { CSS_FILE => "text/css; charset=utf-8", JS_FILE => "text/javascript; charset=utf-8" }.freeze

    # The engine partial rendered for its icons no longer matches what
    # kit_toggle rewrites: an Alpine binding survived, which would be dead (and
    # noisy) markup on a page with no Alpine.
    class Drift < StandardError; end

    # Who the shell names: the app's name, split as the engine's navbar splits
    # it, its CTO's portrait as the mark (one per theme when the portrait follows
    # the colour scheme: Mark), and both sides of its palette.
    Identity = Struct.new(:name, :mark_light_uri, :mark_dark_uri, :light, :dark, keyword_init: true) do
      def words = name.to_s.split
      def name_lead = words[0..-2].join(" ")
      def name_last = words.last.to_s

      def digest
        Digest::SHA256.hexdigest(JSON.generate([ name, mark_light_uri, mark_dark_uri, light, dark ]))
      end
    end

    # The page frame for one app: what goes in the <head>, after <body>, and
    # before </body>. `digest` is the digest of those rendered bytes, so ANY
    # change to what a visitor would see (a template, a footer fact, the menu,
    # the theme, the kit's version) is a new ETag on every page.
    Shell = Struct.new(:head, :navbar, :footer, :digest, keyword_init: true)

    SHELL_CACHE_LIMIT = 256
    # After the kit fails to build or render, pages are served without it, and
    # nothing retries the build (a Tailwind run) until this many seconds pass.
    FAILURE_BACKOFF = 300
    @shell_cache = {}
    @shell_cache_mutex = Mutex.new
    @kit_mutex = Mutex.new
    @failed_at = nil

    class << self
      # { "studio-kit.css" => bytes, "studio-kit.js" => bytes }, built once per
      # process, under a lock, so concurrent first requests build it once.
      # Raises when it cannot be built; callers go through shell_for and
      # asset_for, which never raise.
      def assets
        @assets || @kit_mutex.synchronize do
          @assets ||= { CSS_FILE => Css.compiled + footer_css, JS_FILE => ASSET_DIR.join(JS_FILE).binread }.freeze
        end
      end

      # The kit's version: the digest of what it serves, so a changed kit is a
      # new URL and the old one can be cached for a year.
      def version
        @version ||= Digest::SHA256.hexdigest(assets.sort.flatten.join("\0"))[0, 12]
      end

      def asset_path(file) = "#{PATH_PREFIX}#{version}/#{file}"

      # The kit file a request path names, as [bytes, content_type, current?],
      # or nil (an unknown file, or a kit that cannot be built now). A path
      # naming an older version answers with the current files (a page rendered
      # just before a deploy still gets a kit), but is not cached as immutable:
      # `current?` is false.
      def asset_for(path)
        match = path.to_s.match(%r{\A#{Regexp.escape(PATH_PREFIX)}([0-9a-f]{12})/([a-z.-]+)\z})
        return nil unless match && CONTENT_TYPES.key?(match[2])

        guarded { [ assets.fetch(match[2]), CONTENT_TYPES.fetch(match[2]), match[1] == version ] }
      end

      # The identity for APP: its CTO's palette and portrait, else the app's
      # theme, else the host's defaults (the same reader as the "being built"
      # page).
      def identity_for(app)
        site = BeingBuilt.for(app.slug, app)
        name = (site&.name.presence || app.name.presence || app.slug).to_s.squish
        light_svg, dark_svg = Mark.variants(site&.portrait_svg)
        Identity.new(name: name, mark_light_uri: Mark.data_uri(light_svg), mark_dark_uri: Mark.data_uri(dark_svg),
                     light: Pages.colours(site&.light, Pages::DEFAULT_LIGHT),
                     dark: Pages.colours(site&.dark, Pages::DEFAULT_DARK))
      end

      # The rendered shell for APP, cached per kit version and identity, so a
      # page view renders no template. nil when the kit cannot be built or
      # rendered: the host then serves the page as the bundle wrote it, and the
      # build is not retried for FAILURE_BACKOFF seconds (the failure is
      # recorded once per window). A broken kit never takes an app down.
      def shell_for(app)
        return nil if backing_off?

        identity = identity_for(app) # a database error is the host's 500, never the kit's backoff
        guarded do
          key = "#{version}:#{identity.digest}"
          cached = shell_cache_mutex.synchronize { shell_cache[key] }
          next cached if cached

          shell = render_shell(identity)
          shell_cache_mutex.synchronize do
            shell_cache.shift while shell_cache.size >= SHELL_CACHE_LIMIT
            shell_cache[key] = shell
          end
        end
      end

      def render_shell(identity)
        head = head_html(identity)
        navbar = Renderer.navbar(identity, kit_toggle(Renderer.engine_toggle))
        footer = Renderer.footer(identity)
        Shell.new(head: head, navbar: navbar, footer: footer,
                  digest: Digest::SHA256.hexdigest([ head, navbar, footer ].join("\0"))[0, 16])
      end

      # Whether the kit is in its failure backoff.
      def backing_off?
        failed_at = @failed_at
        !failed_at.nil? && clock - failed_at < FAILURE_BACKOFF
      end

      # The page HTML wrapped in the shell (Wrap does the placing).
      # KEY names the page's bytes (its sha256), so the insertion points are
      # found once per page per process.
      def wrap(html, shell, key: nil) = Wrap.call(html, shell, key: key)

      # What goes at the top of <head>: the kit's stylesheet, the app's theme,
      # then the kit's script, which sets the theme before the first paint. The
      # bundle's own <link>s follow, so its CSS still has the last word.
      def head_html(identity)
        <<~HTML.strip
          <link rel="stylesheet" href="#{asset_path(CSS_FILE)}" data-studio-kit>
          <style data-studio-theme>#{theme_css(identity)}</style>
          <script src="#{asset_path(JS_FILE)}" data-studio-kit></script>
        HTML
      end

      # The app's theme: the engine's full token set (Studio::ThemeResolver),
      # once per side of its palette, keyed on the root's `dark` class as the
      # engine's dark mode is. The palette's own four names (--primary,
      # --accent, --surface, --text) ride beside them, because a bundle styles
      # its content with those; html.dark and html:not(.dark) outrank a
      # bundle's :root, so its colours follow the navbar's toggle too.
      def theme_css(identity)
        side = lambda do |colours, mode|
          resolver = Studio::ThemeResolver.new(primary: colours["primary"], accent: colours["accent"],
                                               mode == :dark ? :dark : :light => colours["surface"])
          vars = mode == :dark ? resolver.dark_mode_vars : resolver.light_mode_vars
          vars = vars.merge(resolver.primary_palette_vars).merge("--color-text" => colours["text"])
          vars = vars.merge(AppPalette::KEYS.to_h { |key| [ "--#{key}", colours[key] ] })
          vars.map { |name, value| "#{name}: #{value};" }.join(" ") + " color-scheme: #{mode};"
        end
        "html:not(.dark) { #{side.call(identity.light, :light)} } html.dark { #{side.call(identity.dark, :dark)} }"
      end

      # The engine's theme-toggle button with its Alpine bindings rewritten to
      # the kit's hooks: the click to data-studio-kit-theme-toggle (studio-kit.js),
      # each icon's x-show to data-studio-kit-when (shell.css). Raises Drift when
      # an Alpine binding is left, so an engine change is caught by the test
      # suite rather than shipped as a dead button.
      def kit_toggle(html)
        out = html.to_s.gsub(/<!--.*?-->/m, "")
                  .sub(/\s@click="\$store\.theme\.toggle\(\)"/,
                       ' type="button" data-studio-kit-theme-toggle data-studio-kit-icon-button aria-pressed="false" aria-label="Toggle dark mode"')
                  .gsub(/\sx-show="\$store\.theme\.isDark"/, ' data-studio-kit-when="dark" aria-hidden="true"')
                  .gsub(/\sx-show="!\$store\.theme\.isDark"/, ' data-studio-kit-when="light" aria-hidden="true"')
                  .gsub(/\sx-cloak\b/, "")
        raise Drift, "the engine's theme toggle has a binding the kit does not rewrite" if out.match?(/\s(?:x-[\w.:-]+|@[\w.:-]+|:[\w-]+)=/)
        raise Drift, "the engine's theme toggle has no click the kit can take" unless out.include?("data-studio-kit-theme-toggle")

        out.squish.html_safe # rubocop:disable Rails/OutputSafety -- engine partial output, rewritten above
      end

      # The site footer's scoped CSS, as the engine ships it (the <style> of
      # studio/site_footer/_assets).
      def footer_css
        Renderer.engine_footer_assets.scan(%r{<style[^>]*>(.*?)</style>}m).flatten.join("\n")
      end

      def reset!
        @assets = @version = @failed_at = nil
        shell_cache_mutex.synchronize { shell_cache.clear }
      end

      private

      # Runs the block unless the kit is backing off; a failure starts the
      # backoff, is recorded (once per window, since nothing retries inside
      # one), and answers nil.
      def guarded
        return nil if backing_off?

        yield
      rescue StandardError => e
        @failed_at = clock
        Rails.logger.error("[studio-kit] serving pages without the kit for #{FAILURE_BACKOFF}s: #{e.class}: #{e.message}")
        Host.record_failure(e, nil)
        nil
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      attr_reader :shell_cache, :shell_cache_mutex
    end
  end
end
