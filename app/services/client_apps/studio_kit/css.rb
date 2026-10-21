# frozen_string_literal: true

require "open3"
require "securerandom"

module ClientApps
  module StudioKit
    # The kit's stylesheet, compiled from the ENGINE's CSS by the hub's own
    # Tailwind (tailwindcss-ruby, the binary tailwindcss-rails builds the hub
    # with), against only the kit's templates:
    #
    #   - the engine's theme (tailwind/studio.tailwind.config.js: the page,
    #     surface, heading and primary colour utilities read the ThemeResolver
    #     tokens) and class-based dark mode;
    #   - engine.css: its @utility primitives (btn, btn-primary, card, badge,
    #     input-field, ...) and the navbar's nav-shell band table;
    #   - Tailwind's theme and utilities layers, but NOT its preflight: the
    #     kit goes onto pages whose own CSS was written without a reset, and a
    #     reset would restyle their content;
    #   - the kit's shell.css, last.
    #
    # Only the classes the kit's templates (and the engine toggle partial they
    # render) use are emitted, plus the engine primitives the builder is told
    # it may use (SAFELIST).
    #
    # BUILT AT DEPLOY. `bin/rails studio_kit:build` is a prerequisite of
    # assets:precompile (lib/tasks/studio_kit.rake), which the Heroku build runs,
    # and writes app/assets/builds/studio_kit/<digest>.css into the slug. The
    # digest is of CONTENT only (the engine and Tailwind versions, and each
    # input's bytes under its path RELATIVE to its root), never an absolute
    # path: Heroku builds in /tmp/build_<hash> and runs in /app, and the two
    # must name the same file, or every dyno would compile on its first
    # client-app request.
    #
    # A process that finds no file for the current digest (development, test,
    # a deploy that skipped the build) compiles it once: a process-wide mutex
    # serialises threads, an flock serialises processes (each re-checks for the
    # file once it holds the lock), and the output is written under a unique
    # temporary name and renamed into place.
    module Css
      # The engine primitives a bundle may use in its own markup, compiled even
      # though no kit template uses them.
      SAFELIST = %w[btn btn-primary btn-secondary btn-outline btn-neutral btn-sm btn-lg card card-hover badge
                    input-field label-upper empty-state].freeze
      OUT_SUBDIR = "app/assets/builds/studio_kit"
      ENGINE_TOKEN = "{{ENGINE_ROOT}}"
      CONFIG_TOKEN = "{{CONFIG}}"
      ENGINE_CSS = "app/assets/tailwind/studio_engine/engine.css"
      ENGINE_CONFIG = "tailwind/studio.tailwind.config.js"
      ENGINE_SOURCES = %w[app/views/components/_theme_toggle.html.erb].freeze
      SHELL_CSS = "app/assets/studio_kit/shell.css"

      class BuildFailed < StandardError; end

      @mutex = Mutex.new

      class << self
        def compiled
          path = output_path
          return path.read if path.file?

          @mutex.synchronize { locked_build(path) }
        end

        # Compiles the kit, unless another thread or process already did.
        def locked_build(path = output_path)
          return path.read if path.file?

          FileUtils.mkdir_p(path.dirname)
          File.open(path.dirname.join(".build.lock"), File::RDWR | File::CREAT, 0o644) do |lock|
            lock.flock(File::LOCK_EX)
            path.file? ? path.read : build!(path)
          end
        end

        # Compiles the kit into PATH (always; the rake task's entry point).
        def build!(path = output_path)
          FileUtils.mkdir_p(path.dirname)
          Dir.mktmpdir("studio-kit") do |dir|
            input = File.join(dir, "input.css")
            config = File.join(dir, "tailwind.config.js")
            File.write(config, config_js)
            File.write(input, input_css(config))
            out = File.join(dir, "out.css")
            _stdout, stderr, status = Open3.capture3(executable, "-i", input, "-o", out, "--minify", chdir: Rails.root.to_s)
            raise BuildFailed, "tailwindcss failed: #{stderr.lines.last(5).join}" unless status.success? && File.file?(out)

            css = "/* McRitchie Studio kit #{digest} (studio-engine #{engine_version}) */\n#{File.read(out)}"
            tmp = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
            File.write(tmp, css)
            File.rename(tmp, path)
            css
          ensure
            FileUtils.rm_f(tmp) if tmp
          end
        end

        def output_path(root = Rails.root) = Pathname(root).join(OUT_SUBDIR, "#{digest}.css")

        # The digest of everything the compile reads, by content. Absolute
        # paths are replaced by tokens, and each source is named by its path
        # relative to its own root, so two checkouts of one tree (a build
        # directory and the running slug) agree.
        def digest(app_root: Rails.root, engine_root: self.engine_root)
          parts = [ engine_version, executable_version,
                    config_js(ENGINE_TOKEN), input_css(CONFIG_TOKEN, app_root: app_root, engine_root: engine_root, tokens: true) ]
          sources(app_root: app_root, engine_root: engine_root).each do |root, relative|
            parts << relative << File.binread(File.join(root.to_s, relative))
          end
          parts << File.binread(File.join(engine_root.to_s, ENGINE_CSS)) << File.binread(File.join(engine_root.to_s, ENGINE_CONFIG))
          Digest::SHA256.hexdigest(parts.join("\0"))[0, 16]
        end

        def engine_root = Studio::Engine.root

        def engine_version = Gem.loaded_specs["studio-engine"]&.version.to_s

        def executable
          require "tailwindcss/ruby"
          Tailwindcss::Ruby.executable
        end

        def executable_version = Gem.loaded_specs["tailwindcss-ruby"]&.version.to_s

        # What Tailwind scans for class names, as [root, relative path]: the
        # kit's own templates and the engine partials the kit renders.
        def sources(app_root: Rails.root, engine_root: self.engine_root)
          kit = Dir.glob("app/views/client_apps/kit/*.erb", base: app_root.to_s).sort.map { |rel| [ app_root, rel ] }
          kit + ENGINE_SOURCES.map { |rel| [ engine_root, rel ] }
        end

        def config_js(engine = engine_root)
          path = engine == ENGINE_TOKEN ? "#{ENGINE_TOKEN}/#{ENGINE_CONFIG}" : File.join(engine.to_s, ENGINE_CONFIG)
          <<~JS
            const studio = require(#{path.to_json});
            module.exports = { darkMode: 'class', content: [], theme: studio.theme };
          JS
        end

        # The Tailwind input. With tokens: true every absolute path is a token
        # (for the digest); otherwise the real paths (for the compile).
        def input_css(config, app_root: Rails.root, engine_root: self.engine_root, tokens: false)
          at = ->(root, rel) { tokens ? "#{root == engine_root ? ENGINE_TOKEN : '{{APP_ROOT}}'}/#{rel}" : File.join(root.to_s, rel) }
          <<~CSS
            @layer theme, base, components, utilities;
            @import "tailwindcss/theme.css" layer(theme);
            @import "tailwindcss/utilities.css" layer(utilities) source(none);
            @import #{at.call(engine_root, ENGINE_CSS).to_json};
            @config #{config.to_json};
            @source not #{at.call(engine_root, 'app/components').to_json};
            #{sources(app_root: app_root, engine_root: engine_root).map { |root, rel| "@source #{at.call(root, rel).to_json};" }.join("\n")}
            @source inline(#{SAFELIST.join(' ').to_json});
            #{File.read(File.join(app_root.to_s, SHELL_CSS))}
          CSS
        end
      end
    end
  end
end
