# frozen_string_literal: true

require "test_helper"
require_relative "../support/client_bundle_fixtures"

# [integration] The Studio template on the shared client-app host, against the
# real middleware stack (docs/agents/system/client-app-host.md, "The Studio
# template"): every page of every app is wrapped at serve time in the engine's
# navbar and footer, in the app's palette, and loads ONE shared kit from
# /_studio/kit/<version>/ on its own origin, under the bundle CSP.
class ClientAppStudioKitTest < ActionDispatch::IntegrationTest
  include ClientBundleFixtures

  def preview(sub) = host!("#{sub}.localhost")

  def publish!(app, files = bundle_files) = ClientApps::Publish.new(app: app, files: files, by: "test").call

  def kit = ClientApps::StudioKit

  setup do
    ClientApps::BundleStore.clear_cache!
    kit.reset!
  end

  test "[integration] kit export renders the engine navbar and footer for an app's name and theme" do
    app = client_app_with_build_task!(slug: "pawsome")
    app.update!(name: "Pawsome Grooming")
    app.client_cto.update!(palette: { "light" => { "primary" => "#9F1239", "accent" => "#D97706", "surface" => "#FFFBF5", "text" => "#1C1917" },
                                      "dark" => { "primary" => "#FB7185", "accent" => "#FBBF24", "surface" => "#1C1917", "text" => "#FAFAF9" } })
    publish!(app)
    preview("pawsome")

    get "/"
    assert_response :success
    html = response.body
    doc = Nokogiri::HTML5(html)

    navbar = doc.at_css("body > header[data-studio-navbar].nav-shell")
    assert navbar, "the engine navbar contract (nav-shell) opens the body"
    assert_equal doc.at_css("body").element_children.first, navbar, "the navbar is the body's first child"
    assert_equal %w[Pawsome Grooming], navbar.css(".nav-title span").map(&:text), "the engine's split: last word in the primary colour"
    assert_equal "Grooming", navbar.at_css(".nav-title span.text-primary").text
    assert navbar.at_css("img.nav-logo[src^='data:image/svg+xml;base64,']"), "the CTO's portrait is the mark, inline (img-src data:)"
    toggle = navbar.at_css("button[data-studio-kit-theme-toggle]")
    assert toggle, "the engine's theme toggle, rewritten to the kit's hook"
    assert_equal %w[dark light], toggle.css("svg[data-studio-kit-when]").map { |svg| svg["data-studio-kit-when"] }
    assert navbar.at_css("button[data-studio-kit-menu-toggle][aria-controls='studio-kit-menu']")
    assert navbar.at_css("nav#studio-kit-menu[hidden] a[href='https://mcritchie.studio/build']")

    footer = doc.at_css("body > footer[data-studio-footer].ftr[data-site-footer]")
    assert footer, "the engine's site footer partial closes the body"
    assert_equal "https://mcritchie.studio", footer.at_xpath(".//a[normalize-space()='Built with McRitchie Studio']")&.[]("href")
    assert_includes footer.at_css(".ftr-copyright").text, "Pawsome Grooming"
    assert doc.at_css("body > main[data-studio-content]"), "the bundle's content stays between them"
    assert_equal "", doc.at_css("body")["data-studio-kit"]

    theme = doc.at_css("head style[data-studio-theme]").text
    assert_includes theme, "html:not(.dark) { --color-page: #FFFBF5;"
    assert_includes theme, "--primary: #9F1239;"
    assert_match(/html\.dark \{ --color-page: #1C1917;.*--primary: #FB7185;/, theme)

    # No inline script, no other origin, no hub route, no comment from a partial.
    assert_empty doc.css("script:not([src])"), "every script is a file"
    assert_empty doc.css("[onclick], [onload]")
    doc.css("script[src], link[rel=stylesheet]").each do |tag|
      url = tag["src"] || tag["href"]
      assert_not url.match?(%r{\A(https?:)?//}), "#{url} is same-origin"
    end
    assert_not_includes html, "<!-- BEGIN", "no template annotation reaches the page"
    assert_not_includes html, "x-data"
    assert_nil response.headers["set-cookie"]
    assert_includes response.headers["content-security-policy"], "script-src 'self'"
  end

  test "[integration] the one shared kit is served on every app, versioned, same-origin and immutable" do
    publish!(client_app_with_build_task!(slug: "pawsome"))
    preview("pawsome")
    get "/"
    css_path = Nokogiri::HTML5(response.body).at_css("link[data-studio-kit]")["href"]
    js_path = Nokogiri::HTML5(response.body).at_css("script[data-studio-kit]")["src"]
    assert_equal "/_studio/kit/#{kit.version}/studio-kit.css", css_path
    assert_equal "/_studio/kit/#{kit.version}/studio-kit.js", js_path

    get css_path
    assert_response :success
    assert_equal "text/css; charset=utf-8", response.headers["content-type"]
    assert_equal "public, max-age=31536000, immutable", response.headers["cache-control"]
    css = response.body
    assert_includes css, ".nav-shell", "the engine's navbar band table"
    assert_match(/\.btn-primary\{/, css, "the engine's button primitives")
    assert_includes css, ".ftr-cols", "the engine footer's scoped CSS"
    assert_includes css, "[data-studio-menu]", "the kit's shell glue"
    assert_no_match(/\A[^{]*\*,:after,:before\{box-sizing/, css, "no Tailwind preflight reset")

    get js_path
    assert_equal "text/javascript; charset=utf-8", response.headers["content-type"]
    assert_includes response.body, "studio-kit-theme"

    get "/_studio/kit/000000000000/studio-kit.css"
    assert_response :success, "an older version's URL still gets the current kit"
    assert_equal "public, max-age=300", response.headers["cache-control"], "but is not cached as immutable"

    get "/_studio/kit/#{kit.version}/nope.js"
    assert_response :not_found

    # The same kit on an app still being built, and none on a name nobody holds.
    client_app!(slug: "cat-naps", name: "Cat Naps")
    preview("cat-naps")
    get css_path
    assert_response :success
    preview("nobody-here")
    get css_path
    assert_response :not_found
  end

  test "[integration] a kit or app change reaches the page on its next request, with a new ETag" do
    app = client_app_with_build_task!(slug: "pawsome")
    publish!(app)
    preview("pawsome")
    get "/"
    etag = response.headers["etag"]
    get "/", headers: { "If-None-Match" => etag }
    assert_response :not_modified

    app.update!(name: "Pawsome Spa")
    get "/", headers: { "If-None-Match" => etag }
    assert_response :success, "a renamed app is a new shell, so the old ETag no longer matches"
    assert_includes response.body, "Pawsome"
    assert_includes Nokogiri::HTML5(response.body).at_css(".nav-title span.text-primary").text, "Spa"
    assert_not_equal etag, response.headers["etag"]
  end

  test "[integration] a bundle published before the template is wrapped too, its own footer hidden" do
    app = client_app_with_build_task!(slug: "pawsome")
    legacy = "<!doctype html><html><head><title>Old</title></head><body><header class=\"topbar\">Tabs</header>" \
             "<main id=\"main\">Notes</main><footer data-site-footer>&copy; Old</footer><script src=\"app.js\"></script></body></html>"
    # Published before the rule: written straight to the store, as the live
    # versions of team-notes and table-ready were.
    version = AppPreviewVersion.mint_version
    files = { "index.html" => legacy, "app.js" => "1" }
    manifest = ClientAppBundle.new(files).manifest
    manifest.each { |path, meta| ClientApps::BundleStore.write(ClientApps::BundleStore.key(app.slug, version, path), files[path], content_type: meta["content_type"]) }
    app.preview_versions.create!(version: version, published_by: "test", file_count: 2, byte_size: 10, manifest: manifest, published_at: Time.current)
    app.update!(preview_version: version)
    preview("pawsome")

    get "/"
    doc = Nokogiri::HTML5(response.body)
    assert doc.at_css("body > header[data-studio-navbar]")
    assert doc.at_css("body > header.topbar"), "the app's own bar is left as written"
    assert doc.at_css("body > footer[data-studio-footer]")
    assert doc.at_css("body > footer[data-site-footer]:not([data-studio-footer])"), "its own footer is kept in the page"
    assert_includes kit.assets["studio-kit.css"], "footer[data-site-footer]:not([data-studio-footer])",
                    "and the kit's CSS hides it, so only the Studio footer shows"
  end

  test "[integration] publish refuses a bundle with no content region or its own navbar or footer" do
    app = client_app_with_build_task!(slug: "pawsome")
    no_region = bundle_files("index.html" => "<!doctype html><title>x</title><h1>Hi</h1>")
    error = assert_raises(ClientAppBundle::Invalid) { publish!(app, no_region) }
    assert(error.errors.any? { |e| e.include?("no content region") })

    own_shell = bundle_files("index.html" => "<!doctype html><body><header>Nav</header><main data-studio-content></main>" \
                                             "<footer data-site-footer>x</footer></body>")
    error = assert_raises(ClientAppBundle::Invalid) { publish!(app, own_shell) }
    assert(error.errors.any? { |e| e.include?("<header> outside") })
    assert(error.errors.any? { |e| e.include?("shell's own hooks") })

    kit_path = bundle_files("_studio/kit/x/studio-kit.css" => "body{}")
    error = assert_raises(ClientAppBundle::Invalid) { publish!(app, kit_path) }
    assert(error.errors.any? { |e| e.include?("under _studio/") })
    assert_nil app.reload.preview_version, "nothing was published"
  end

  test "[integration] a kit that cannot build serves every page unwrapped, records once, and backs off" do
    publish!(client_app_with_build_task!(slug: "pawsome"))
    preview("pawsome")
    attempts = 0
    failing = ->(*) { attempts += 1; raise ClientApps::StudioKit::Css::BuildFailed, "tailwindcss failed: boom" }

    ClientApps::StudioKit::Css.stub(:compiled, failing) do
      assert_difference -> { ErrorLog.count }, 1 do
        get "/"
        assert_response :success, "a broken kit never takes the app down"
        assert_includes response.body, "<main data-studio-content><h1>Pawsome</h1></main>"
        assert_not_includes response.body, "data-studio-navbar", "served as the bundle wrote it"
        etag = response.headers["etag"]
        assert_equal %("#{Digest::SHA256.hexdigest(bundle_files['index.html'])}"), etag

        get "/", headers: { "If-None-Match" => etag }
        assert_response :not_modified
        get "/about"
        assert_response :success
        get "/_studio/kit/000000000000/studio-kit.css"
        assert_response :not_found
      end
      assert_equal 1, attempts, "one compile attempt, then the backoff: no Tailwind run per request"
    end

    # Past the backoff, one request tries again and the shell is back.
    ClientApps::StudioKit.instance_variable_set(:@failed_at, ClientApps::StudioKit.send(:clock) - ClientApps::StudioKit::FAILURE_BACKOFF - 1)
    get "/"
    assert_includes response.body, "data-studio-navbar"
  end

  test "[integration] a footer fact change is a new ETag, so a returning visitor gets the new shell" do
    publish!(client_app_with_build_task!(slug: "pawsome"))
    preview("pawsome")
    get "/"
    etag = response.headers["etag"]

    kit.reset!
    renderer = ClientApps::StudioKit::Renderer
    original = renderer.method(:footer_facts)
    facts = ->(identity) { original.call(identity).merge(tagline: "Now with a tagline") }
    renderer.stub(:footer_facts, facts) do
      get "/", headers: { "If-None-Match" => etag }
      assert_response :success, "the template changed, so the old ETag no longer matches"
      assert_includes response.body, "Now with a tagline"
      assert_not_equal etag, response.headers["etag"]
    end
  ensure
    kit.reset!
  end
end
