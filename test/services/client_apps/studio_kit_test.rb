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
    assert_match %r{\A<!doctype html>\n<head>\n<HEAD/>\n</head>\n<body data-studio-kit>\n<NAV/>\n\n<title>T</title>}, out
    assert out.end_with?("<FOOT/>\n")

    bare = wrap("<p>hi</p>")
    assert_equal [ 0, 1, 1 ], [ bare.index("<head>"), bare.scan("<NAV/>").size, bare.scan("<FOOT/>").size ]
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
    identity = Kit::Identity.new(name: %(<script>alert(1)</script> "Pets"), mark_uri: nil,
                                 light: ClientApps::Pages::DEFAULT_LIGHT, dark: ClientApps::Pages::DEFAULT_DARK)
    shell = Kit.render_shell(identity, "k")
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

  test "[unit] the kit fits inside a bundle's own limits with room to spare" do
    total = Kit.assets.values.sum(&:bytesize)
    assert_operator total, :<, 100_000, "the kit is #{total} bytes, served once per app and cached a year"
  end
end
