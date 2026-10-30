# frozen_string_literal: true

require "test_helper"

# [unit] ClientApps::StudioKit: the Studio template the shared host wraps every
# client app page in (docs/agents/system/client-app-host.md, "The Studio
# template").
class ClientApps::StudioKitTest < ActiveSupport::TestCase
  Kit = ClientApps::StudioKit
  SHELL = Kit::Shell.new(head: "<HEAD/>", navbar: "<NAV/>", footer: "<FOOT/>", digest: "d")

  def wrap(html) = Kit::Wrap.call(html, SHELL)

  test "[unit] the shell goes at the head's top, after <body>, and before the last </body>" do
    page = %(<!doctype html><html lang="en"><head><meta charset="utf-8"><link rel="stylesheet" href="styles.css"></head>) +
           %(<body class="x"><main data-studio-content>Hi</main><script src="app.js"></script></body></html>)
    out = wrap(page)
    assert_equal page.length + "<HEAD/><NAV/><FOOT/> data-studio-kit".length + 5, out.length, "nothing else is touched"
    assert_operator out.index("<HEAD/>"), :<, out.index(%(<link rel="stylesheet" href="styles.css">)),
                    "the kit comes first, so the bundle's own CSS has the last word"
    assert_includes out, %(<body data-studio-kit class="x">\n<NAV/>\n<main)
    assert_includes out, %(</script><FOOT/>\n</body></html>)
  end

  test "[unit] a header element is not the head, and the LAST </body> takes the footer" do
    out = wrap(%(<html><head></head><body><header>h</header><p>"</body>" in text</p></body></html>))
    assert_equal 1, out.scan("<HEAD/>").size
    assert out.index("<HEAD/>") < out.index("<header>")
    assert_match %r{in text</p><FOOT/>\n</body></html>\z}, out
  end

  test "[unit] a page missing its tags still gets the whole shell, in order" do
    out = wrap("<!doctype html><title>T</title><main data-studio-content>x</main>")
    assert_match %r{\A<!doctype html>\n<head>\n<HEAD/>\n</head>\n\n<body data-studio-kit>\n<NAV/>\n<title>T</title>}, out
    assert out.end_with?("<FOOT/>\n")

    bare = wrap("<p>hi</p>")
    assert_equal [ true, 1, 1 ], [ bare.lstrip.start_with?("<head>"), bare.scan("<NAV/>").size, bare.scan("<FOOT/>").size ]
    assert_operator bare.index("<NAV/>"), :<, bare.index("<p>hi</p>")
  end

  test "[unit] the engine's theme toggle is rewritten to the kit's hooks, and drift is refused" do
    toggle = Kit.kit_toggle(Kit::Renderer.engine_toggle)
    assert_includes toggle, "data-studio-kit-theme-toggle"
    assert_includes toggle, %(data-studio-kit-when="dark")
    assert_includes toggle, %(data-studio-kit-when="light")
    assert_no_match(/x-show|@click|x-cloak|<!--/, toggle)

    assert_raises(Kit::Drift) { Kit.kit_toggle(%(<button @click="$store.theme.toggle()" x-bind:class="a">x</button>)) }
    assert_raises(Kit::Drift) { Kit.kit_toggle(%(<button @click="$store.theme.flip()">x</button>)) }
  end

  # Newer studio-engine renders a toggle that names itself (/tasks/engine-theme-toggle-labels).
  # Held inline so this passes against either engine the hub locks.
  NAMED_TOGGLE = <<~HTML.freeze
    <button type="button" @click="$store.theme.toggle()" class="flex" title="Toggle theme" aria-label="Dark theme" :aria-pressed="$store.theme.isDark ? 'true' : 'false'">
      <svg x-show="$store.theme.isDark" class="w-4 h-4"></svg>
      <svg x-show="!$store.theme.isDark" x-cloak class="w-4 h-4"></svg>
    </button>
  HTML

  test "[unit] the engine's self-naming toggle rewrites to the kit's hooks with one of each attribute" do
    toggle = Kit.kit_toggle(NAMED_TOGGLE)
    button = Nokogiri::HTML5.fragment(toggle).at_css("button")

    assert_equal "button", button["type"]
    assert_equal "Toggle dark mode", button["aria-label"], "the kit's own label, not the engine's"
    assert_equal "false", button["aria-pressed"], "studio-kit.js keeps it from here"
    assert_equal 1, toggle.scan(/\stype=/).size
    assert_equal 1, toggle.scan(/\saria-label=/).size
    assert_equal 1, toggle.scan(/\saria-pressed=/).size
    assert_no_match(/:aria-pressed|x-show|@click|x-cloak/, toggle)
  end

  test "[unit] an aria-pressed binding other than the engine's still drifts" do
    other = NAMED_TOGGLE.sub("$store.theme.isDark ? 'true' : 'false'", "$store.theme.value")
    assert_raises(Kit::Drift) { Kit.kit_toggle(other) }
  end

  test "[unit] the theme is the engine's token set per side of the palette, with the palette's own names" do
    identity = Kit::Identity.new(name: "Table Ready", light: { "primary" => "#9F1239", "accent" => "#D97706", "surface" => "#FFFBF5", "text" => "#1C1917" },
                                 dark: { "primary" => "#FB7185", "accent" => "#FBBF24", "surface" => "#1C1917", "text" => "#FAFAF9" })
    css = Kit.theme_css(identity)
    light, dark = css.split("html.dark")
    expected_light = Studio::ThemeResolver.new(primary: "#9F1239", light: "#FFFBF5").light_mode_vars
    assert_includes light, "--color-text-secondary: #{expected_light['--color-text-secondary']};", "the engine's AA-derived ink"
    assert_includes light, "--color-primary-500-rgb:", "the engine's primary scale"
    assert_includes light, "--surface: #FFFBF5;"
    assert_includes light, "color-scheme: light;"
    assert_includes dark, "--color-page: #1C1917;"
    assert_includes dark, "--primary: #FB7185;"
    assert_includes dark, "--color-text: #FAFAF9;"
  end

  test "[unit] a client's words never break out of the shell" do
    identity = Kit::Identity.new(name: %(<script>alert(1)</script> "Pets"),
                                 light: ClientApps::Pages::DEFAULT_LIGHT, dark: ClientApps::Pages::DEFAULT_DARK)
    shell = Kit.render_shell(identity)
    [ shell.navbar, shell.footer ].each do |html|
      assert_not_includes html, "<script>alert"
      assert_includes html, "&lt;script&gt;"
    end
  end

  test "[unit] the kit's CSS is compiled from the engine and its version is its content's digest" do
    css = Kit.assets.fetch("studio-kit.css")
    assert_includes css, "studio-engine #{Gem.loaded_specs['studio-engine'].version}"
    Kit::Css::SAFELIST.each { |name| assert_includes css, ".#{name}", "#{name} is compiled for the builder to use" }
    assert_equal Digest::SHA256.hexdigest(Kit.assets.sort.flatten.join("\0"))[0, 12], Kit.version
    assert_equal "/_studio/kit/#{Kit.version}/studio-kit.js", Kit.asset_path("studio-kit.js")
    assert_nil Kit.asset_for("/_studio/kit/#{Kit.version}/../secrets")
  end

  # studio-engine 0.114.2 moved the theme into theme.css, which engine.css
  # imports; the JS preset is a deprecated shim due for removal, and a kit that
  # still read it would break at request time when it goes.
  test "[unit] the kit compiles CSS-first, with no @config and no JS preset" do
    input = Kit::Css.input_css
    refute_match(/@config\b/, input)
    refute_match(/studio\.tailwind\.config|\.js["']/, input)
    assert_includes input, Kit::Css.engine_root.join(Kit::Css::ENGINE_CSS).to_s
    refute Kit::Css.const_defined?(:ENGINE_CONFIG), "the kit names the JS preset again"

    css = Kit.assets.fetch("studio-kit.css")
    assert css.include?(".text-heading{"), "the theme's ink utilities no longer reach the kit"
  end

  test "[unit] the kit fits inside a bundle's own limits with room to spare" do
    total = Kit.assets.values.sum(&:bytesize)
    assert_operator total, :<, 100_000, "the kit is #{total} bytes, served once per app and cached a year"
  end

  # --- Carl's tricky pages (PR 2213 review): the wrap and the publish check read
  # a page through one scanner, so neither is fooled by a <body> that is text.

  TRICKY = {
    "a comment in head" => %(<!doctype html><html><head><!-- layout: <body> --><title>T</title></head><body><main data-studio-content>C</main></body></html>),
    "body in title" => %(<!doctype html><html><head><title>Use <body> wisely</title></head><body><main data-studio-content>C</main></body></html>),
    "body in a meta attribute" => %(<!doctype html><html><head><meta name="x" content="<body>"></head><body><main data-studio-content>C</main></body></html>),
    "body in a script" => %(<!doctype html><html><head><script src="a.js">document.write("<body>")</script></head><body><main data-studio-content>C</main></body></html>),
    "uppercase BODY" => %(<!DOCTYPE html><HTML><HEAD><TITLE>T</TITLE></HEAD><BODY><main data-studio-content>C</main></BODY></HTML>),
    "body with attributes" => %(<!doctype html><html><head></head><body class="app" data-x='a>b'><main data-studio-content>C</main></body></html>),
    "missing body" => %(<!doctype html><html><head><title>T</title></head><main data-studio-content>C</main></html>),
    "two bodies" => %(<!doctype html><html><head></head><body id="one"><main data-studio-content>C</main><body id="two"></body></html>)
  }.freeze

  test "[unit] Carl's eight tricky pages: the shell lands whole, in place, and nothing else moves" do
    shell = Kit::Shell.new(head: %(<link rel="stylesheet" href="/k.css" data-studio-kit>), navbar: %(<header data-studio-navbar>N</header>),
                           footer: %(<footer data-studio-footer>F</footer>), digest: "d")
    TRICKY.each do |name, page|
      assert_empty ClientAppBundle.template_errors("index.html", page), "#{name}: publish accepts it"
      out = Kit::Wrap.call(page, shell)
      doc = Nokogiri::HTML5(out)
      body = doc.at_css("body")
      assert_equal 1, doc.css("header[data-studio-navbar]").size, "#{name}: one navbar"
      assert_equal "header", body.element_children.first.name, "#{name}: the navbar opens the body"
      assert body.key?("data-studio-kit"), "#{name}: the body carries the kit hook"
      assert_equal "footer", body.element_children.last.name, "#{name}: the footer closes the body"
      assert doc.at_css("head link[data-studio-kit]"), "#{name}: the kit's head pieces are in the head"
      assert_operator out.index("data-studio-navbar"), :<, out.index("data-studio-content"), "#{name}: navbar before content"
      assert_equal 1, doc.css("main[data-studio-content]").size, "#{name}: the content is untouched"
    end
    assert_equal "Use <body> wisely", Nokogiri::HTML5(Kit::Wrap.call(TRICKY["body in title"], shell)).title
    assert_equal "<body>", Nokogiri::HTML5(Kit::Wrap.call(TRICKY["body in a meta attribute"], shell)).at_css("meta")["content"]
    assert_includes Kit::Wrap.call(TRICKY["a comment in head"], shell), "<!-- layout: <body> -->"
    assert_equal "app", Nokogiri::HTML5(Kit::Wrap.call(TRICKY["body with attributes"], shell)).at_css("body")["class"]
  end

  test "[unit] publish refuses a page the host would wrap wrongly: a late <body>, or a region only in a comment" do
    late = %(<html><head></head><main data-studio-content>C</main><body></body></html>)
    assert(ClientAppBundle.template_errors("index.html", late).any? { |e| e.include?("opens <body> after its content region") })
    commented = %(<body><!-- <main data-studio-content> --><p>x</p></body>)
    assert(ClientAppBundle.template_errors("index.html", commented).any? { |e| e.include?("no content region") })
    in_title = %(<head><title><main data-studio-content></title></head><body><p>x</p></body>)
    assert(ClientAppBundle.template_errors("index.html", in_title).any? { |e| e.include?("no content region") })
  end

  test "[unit] a portrait that follows the colour scheme becomes one fixed mark per theme" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"><style>.f{fill:#111}@media (prefers-color-scheme: dark){.f{fill:#eee}}</style><rect class="f"/></svg>)
    light, dark = Kit::Mark.variants(svg)
    assert_equal %(<svg xmlns="http://www.w3.org/2000/svg"><style>.f{fill:#111}</style><rect class="f"/></svg>), light
    assert_equal %(<svg xmlns="http://www.w3.org/2000/svg"><style>.f{fill:#111}.f{fill:#eee}</style><rect class="f"/></svg>), dark
    assert_equal [ "<svg/>", nil ], Kit::Mark.variants("<svg/>"), "a fixed portrait is one mark"

    identity = Kit::Identity.new(name: "Pets", mark_light_uri: Kit::Mark.data_uri(light), mark_dark_uri: Kit::Mark.data_uri(dark),
                                 light: ClientApps::Pages::DEFAULT_LIGHT, dark: ClientApps::Pages::DEFAULT_DARK)
    navbar = Nokogiri::HTML5.fragment(Kit.render_shell(identity).navbar)
    assert_equal %w[light dark], navbar.css("img.nav-logo").map { |img| img["data-studio-kit-when"] },
                 "the kit's CSS shows the one matching the root's dark class"
  end

  test "[unit] the CSS digest is content-only: two checkouts of one tree agree, an edit does not" do
    Dir.mktmpdir do |one|
      Dir.mktmpdir do |two|
        copy = lambda do |root|
          app, engine = File.join(root, "hub"), File.join(root, "deep/engine")
          Kit::Css.sources.each do |source_root, rel|
            dest = File.join(source_root == Kit::Css.engine_root ? engine : app, rel)
            FileUtils.mkdir_p(File.dirname(dest))
            FileUtils.cp(File.join(source_root.to_s, rel), dest)
          end
          [ [ Rails.root, Kit::Css::SHELL_CSS, app ], [ Kit::Css.engine_root, Kit::Css::ENGINE_CSS, engine ],
            [ Kit::Css.engine_root, Kit::Css::ENGINE_THEME_CSS, engine ] ].each do |from, rel, to|
            FileUtils.mkdir_p(File.dirname(File.join(to, rel)))
            FileUtils.cp(File.join(from.to_s, rel), File.join(to, rel))
          end
          [ Pathname(app), Pathname(engine) ]
        end
        app_one, engine_one = copy.call(one)
        app_two, engine_two = copy.call(two)
        first = Kit::Css.digest(app_root: app_one, engine_root: engine_one)
        assert_equal first, Kit::Css.digest(app_root: app_two, engine_root: engine_two), "a moved checkout names the same file"
        assert_equal Kit::Css.digest, first, "and the real checkout names it too"

        File.write(app_two.join(Kit::Css::SHELL_CSS), "/* edited */", mode: "a")
        assert_not_equal first, Kit::Css.digest(app_root: app_two, engine_root: engine_two), "an edited input is a new kit"

        # The copies carry no tailwind/studio.tailwind.config.js, so a digest
        # that still read the JS preset would raise above. theme.css is what
        # engine.css imports for the tokens: a token edit is a new kit.
        File.write(engine_one.join(Kit::Css::ENGINE_THEME_CSS), "/* edited */", mode: "a")
        assert_not_equal first, Kit::Css.digest(app_root: app_one, engine_root: engine_one), "an edited theme.css is a new kit"
      end
    end
  end

  test "[unit] concurrent cold requests compile the kit once, and read the prebuilt file after" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("app/assets/builds/studio_kit/abc.css")
      builds = Concurrent::AtomicFixnum.new(0)
      build = lambda do |target|
        builds.increment
        sleep 0.05
        FileUtils.mkdir_p(target.dirname)
        File.write(target, "/* kit */")
        "/* kit */"
      end
      Kit::Css.stub(:output_path, path) do
        Kit::Css.stub(:build!, build) do
          results = Array.new(6) { Thread.new { Kit::Css.compiled } }.map(&:value)
          assert_equal [ "/* kit */" ], results.uniq
          assert_equal 1, builds.value, "six threads, one compile"
          Kit::Css.compiled
          assert_equal 1, builds.value, "the file on disk is read, never rebuilt"
        end
      end
    end
  end

  test "[unit] the deploy build compiles the kit: studio_kit:build is a prerequisite of assets:precompile" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("studio_kit:build")
    assert_includes Rake::Task["assets:precompile"].prerequisites, "studio_kit:build",
                    "the Heroku Ruby buildpack runs assets:precompile, so the slug carries the compiled kit"
    assert_equal Rails.root.join(Kit::Css::OUT_SUBDIR, "#{Kit::Css.digest}.css"), Kit::Css.output_path
  end
end
