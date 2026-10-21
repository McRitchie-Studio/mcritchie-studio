# frozen_string_literal: true

require "open3"

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
    # it may use (SAFELIST), so it stays small (about 15 KB).
    #
    # Built at deploy (`bin/rails studio_kit:build`, run by assets:precompile)
    # into tmp/studio_kit/<digest of the inputs>.css; a process that finds no
    # file for the current inputs compiles it then (dev, test, a cold dyno).
    # The digest covers the engine version, so an engine bump is a new kit.
    module Css
      # The engine primitives a bundle may use in its own markup, compiled even
      # though no kit template uses them.
      SAFELIST = %w[btn btn-primary btn-secondary btn-outline btn-neutral btn-sm btn-lg card card-hover badge
                    input-field label-upper empty-state].freeze
      OUT_DIR = Rails.root.join("tmp/studio_kit")

      class BuildFailed < StandardError; end

      module_function

      def compiled
        path = output_path
        return path.read if path.file?

        build!(path)
      end

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
          tmp = "#{path}.#{Process.pid}.tmp"
          File.write(tmp, css)
          File.rename(tmp, path)
          css
        end
      end

      def output_path = OUT_DIR.join("#{digest}.css")

      def digest
        parts = [ engine_version, executable_version, config_js, input_css("CONFIG"), *sources.map { |f| File.read(f) } ]
        Digest::SHA256.hexdigest(parts.join("\0"))[0, 16]
      end

      def engine_root = Studio::Engine.root

      def engine_version = Gem.loaded_specs["studio-engine"]&.version.to_s

      def executable
        require "tailwindcss/ruby"
        Tailwindcss::Ruby.executable
      end

      def executable_version = Gem.loaded_specs["tailwindcss-ruby"]&.version.to_s

      # What Tailwind scans for class names: the kit's own templates and the
      # engine partials the kit renders.
      def sources
        [ *Dir[Rails.root.join("app/views/client_apps/kit/*.erb").to_s].sort,
          engine_root.join("app/views/components/_theme_toggle.html.erb").to_s ]
      end

      def config_js
        <<~JS
          const studio = require(#{engine_root.join('tailwind/studio.tailwind.config.js').to_s.to_json});
          module.exports = { darkMode: 'class', content: [], theme: studio.theme };
        JS
      end

      def input_css(config)
        engine_css = engine_root.join("app/assets/tailwind/studio_engine/engine.css")
        <<~CSS
          @layer theme, base, components, utilities;
          @import "tailwindcss/theme.css" layer(theme);
          @import "tailwindcss/utilities.css" layer(utilities) source(none);
          @import #{engine_css.to_s.to_json};
          @config #{config.to_json};
          @source not #{engine_root.join('app/components').to_s.to_json};
          #{sources.map { |file| "@source #{file.to_json};" }.join("\n")}
          @source inline(#{SAFELIST.join(' ').to_json});
          #{ASSET_DIR.join('shell.css').read}
        CSS
      end
    end
  end
end
