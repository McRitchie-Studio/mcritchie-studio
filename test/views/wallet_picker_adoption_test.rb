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

  test "the registered picker RESOLVES to the gem" do
    # The assertion that actually matters. This engine is non-isolated, so an app
    # view at the same path shadows it — which is how the host fork went
    # unnoticed for months. Registering the engine PATH proves nothing on its
    # own; resolving it does.
    template = ApplicationController.new.lookup_context
                                    .find("wallet_connect", ["studio/modals"], true)

    assert_includes template.identifier, "/gems/",
                    "the picker must come from the gem, not a local file"
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
end
