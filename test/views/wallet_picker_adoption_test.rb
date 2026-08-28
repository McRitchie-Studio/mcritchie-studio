# frozen_string_literal: true

require "test_helper"

# [component] This app renders the ENGINE's Connect Wallet picker, not a copy.
#
# It carried its own 107-line fork frozen at turf-monster's pre-0.20 shape: no
# engine partials, three app-served wallet PNGs, and the mobile double-Phantom
# defect turf fixed separately. Adopting deletes all of it.
class WalletPickerAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

  test "the layout registers the engine picker and no local copy survives" do
    assert_includes LAYOUT.read, %(render "studio/modals/wallet_connect")
    refute_includes LAYOUT.read, %(render "modals/wallet_connect"),
                    "the local fork must not still be registered"
    refute File.exist?(Rails.root.join("app/views/modals/_wallet_connect.html.erb")),
           "the forked picker file must be gone, not merely unregistered"
  end

  test "the registered picker RESOLVES outside this app" do
    # The assertion that actually matters. This engine is non-isolated, so an app
    # view at the same path shadows it — which is how the host fork went
    # unnoticed for months. Registering the engine PATH proves nothing on its
    # own; resolving it does.
    #
    # ASSERT THE SHADOW IS ABSENT, NOT THE INSTALL MODE. This assertion used to
    # read `assert_includes template.identifier, "/gems/"`, which encoded HOW the
    # engine happens to be installed rather than WHAT must be true. That passes
    # here, where studio-engine resolves from RubyGems — and can NEVER pass in
    # studio-engine's own consumer-CI lane, which bundles the engine as a PATH
    # checkout and resolves the same correct partial from
    # /home/runner/work/studio-engine/studio-engine/studio/. It went red on the
    # release tip a gem publish would push, which is a consumer assertion
    # red-sealing the PRODUCER. Both install modes are legitimate; a local fork
    # is not, so that is what the assertion names.
    template = ApplicationController.new.lookup_context
                                    .find("wallet_connect", ["studio/modals"], true)

    assert shadow_free?(template.identifier),
           "the picker must resolve to the engine, not to a local file under " \
           "#{Rails.root.join('app/views')} — a shadowing fork is exactly what " \
           "this test exists to catch (resolved: #{template.identifier})"
  end

  # Both install modes are legitimate, and the predicate above must accept BOTH.
  # These two identifiers are not invented: the first is what this app's own CI
  # resolves (studio-engine from RubyGems), the second is the literal path from
  # the studio-engine consumer-CI run that red-sealed the 0.65.1 gem publish
  # (the engine bundled as a path checkout). The previous assertion accepted the
  # first and rejected the second, which is the whole defect — so pin both.
  test "the resolution check accepts a gem install AND a path checkout" do
    gem_install = "/opt/homebrew/lib/ruby/gems/3.3.0/gems/studio-engine-0.65.0" \
                  "/app/views/studio/modals/_wallet_connect.html.erb"
    path_checkout = "/home/runner/work/studio-engine/studio-engine/studio" \
                    "/app/views/studio/modals/_wallet_connect.html.erb"

    assert shadow_free?(gem_install), "a gem install must pass"
    assert shadow_free?(path_checkout),
           "a path checkout must pass — asserting on /gems/ is what broke the " \
           "engine's own release"

    # ...and the predicate must still reject the thing it exists to reject.
    local_fork = Rails.root.join("app/views/studio/modals/_wallet_connect.html.erb").to_s
    refute shadow_free?(local_fork), "a local fork must still fail"
  end

  test "the wallet PNGs the engine sprite replaced are deleted" do
    # blocks/_wallet_brand_sprite exists so no consumer ships these. turf already
    # deleted its copies; carrying them here is dead weight AND a second source
    # of truth for a brand mark.
    %w[wallet-phantom.png wallet-solflare.png wallet-backpack.png].each do |png|
      refute File.exist?(Rails.root.join("public", png)),
             "public/#{png} is superseded by the engine brand sprite"
    end
  end

  test "the mobile branch stays CLOSED while this app ships no deep link" do
    # The safety property of this adoption. The engine picker collapses its
    # mobile Phantom rows only when startPhantomDeepLink exists; this app does
    # not render studio/solana/phantom_deeplink yet (it cannot declare a cluster
    # — see /tasks/declare-hub-solana-cluster). So the install row survives and
    # no dead "Open app" button is painted.
    #
    # Pinned because the failure is INVISIBLE: rendering the deep link without a
    # cluster signs against devnet and reads to the user as a rejected
    # signature, with nothing in the log.
    refute_includes LAYOUT.read, %(render "studio/solana/phantom_deeplink"),
                    "rendering the deep link without a declared cluster signs against devnet"
  end

  private

  # The picker must not resolve to a file this app owns. Deliberately NOT
  # "is it under /gems/": that names an install mode rather than the defect.
  def shadow_free?(identifier)
    !identifier.start_with?(Rails.root.join("app/views").to_s)
  end

end
