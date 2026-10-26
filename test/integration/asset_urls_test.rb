require "test_helper"

# Every asset a hub page links must resolve through Propshaft: a fingerprinted URL
# (name-<digest>.ext) that answers 200 with bytes. This covers the stylesheets
# (the engine head's "tailwind" and "application"), the importmap's JSON pins
# (the engine's included), its modulepreload links, and any <script src>, <link
# href> or <img src> under /assets. A missing stylesheet or image raises at render
# under Propshaft, but importmap-rails RESCUES a pin whose file is missing and
# silently drops it from the map, so the pins get their own check below.
class AssetUrlsTest < ActionDispatch::IntegrationTest
  DIGESTED = %r{\A/assets/.+-[0-9a-f]{8,}\.[a-z0-9]+\z}

  def asset_urls_on(path)
    get path
    follow_redirect! while response.redirect?
    assert_response :success, "#{path} did not render"

    html = response.body
    urls = html.scan(%r{(?:href|src)="(/assets/[^"?#]+)}).flatten
    importmap = html[%r{<script type="importmap"[^>]*>(.*?)</script>}m, 1]
    refute_nil importmap, "#{path} lost its importmap"
    urls += JSON.parse(importmap).fetch("imports").values
    urls.uniq
  end

  def assert_resolves(checked)
    checked.each do |page, url|
      assert_match DIGESTED, url, "#{page} links an undigested asset"
      get url
      assert_response :success, "#{url} (linked from #{page}) did not resolve"
      refute_empty response.body, "#{url} served no bytes"
    end
  end

  test "[integration] every asset on the public pages is fingerprinted and answers 200" do
    pages = [ root_path, about_path, packages_path, agents_path, tasks_path ]

    checked = pages.flat_map { |page| asset_urls_on(page).map { |url| [ page, url ] } }.uniq(&:last)
    assert checked.any? { |_, url| url.match?(%r{/assets/tailwind-\h+\.css\z}) }, "the tailwind build was not linked"
    assert checked.any? { |_, url| url.match?(%r{/assets/application-\h+\.css\z}) }, "application.css was not linked"
    assert checked.any? { |_, url| url.include?("turbo") }, "turbo is no longer pinned"
    assert checked.any? { |_, url| url.include?("/assets/studio/") }, "no studio-engine asset was linked"

    assert_resolves(checked)
  end

  test "[integration] every asset on a signed-in page is fingerprinted and answers 200" do
    log_in_as(users(:alex))
    checked = asset_urls_on(deployments_path).map { |url| [ deployments_path, url ] }
    refute_empty checked

    assert_resolves(checked)
  end

  test "[integration] an avif asset is served as image/avif" do
    url = ActionController::Base.helpers.asset_path("hero/denver-hero-1280.avif")
    assert_match DIGESTED, url
    get url
    assert_response :success
    assert_equal "image/avif", response.media_type
  end

  test "[integration] every importmap pin resolves to a fingerprinted asset" do
    helpers = ActionController::Base.helpers
    importmap = Rails.application.importmap
    pins = importmap.packages
    refute_empty pins
    assert pins.keys.any? { |name| name.start_with?("studio") || pins[name].path.to_s.start_with?("studio/") },
           "the studio-engine pins are gone from the importmap"

    pins.each do |name, package|
      url = helpers.asset_path(package.path)
      assert_match DIGESTED, url, "pin #{name} resolves undigested"
    rescue Propshaft::MissingAssetError => e
      flunk "pin #{name} points at a file Propshaft cannot find: #{e.message}"
    end

    # pin_all_from directories (board/*) resolve through the same resolver.
    imports = JSON.parse(importmap.to_json(resolver: helpers)).fetch("imports")
    assert imports.keys.any? { |name| name.start_with?("board/") }, "the board modules dropped out of the map"
    imports.each { |name, url| assert_match DIGESTED, url, "pin #{name} resolves undigested" }
  end
end
