# frozen_string_literal: true

require "test_helper"

# [unit] The hub declares no :wallet auth method — and that declaration is what
# REMOVES the Solana sign-in routes, rather than merely hiding a button.
#
# Architecture (Mr. McRitchie, 2026-08-31): studio-engine + mcritchie-studio is
# the base template for every app; solana-studio + turf-monster is the web3
# bolt-on. The hub therefore carries no wallet IDENTITY and no user-facing web3.
#
# Config and route-table shape only — no HTTP. The request-level half (the
# sign-in page, and the admin signing console surviving on a magic-link session)
# lives in test/integration/wallet_auth_dropped_test.rb.
class WalletAuthDeclarationTest < ActiveSupport::TestCase
  # Two of the three routes studio-engine draws behind
  # `Studio.auth_method?(:wallet)` (lib/studio.rb). The third is asserted apart —
  # see the phantom-callback test for why it cannot join this loop.
  WALLET_ROUTES = {
    "/auth/solana/nonce"  => :get,
    "/auth/solana/verify" => :post
  }.freeze

  test "auth_methods is exactly magic_link and google" do
    assert_equal %i[magic_link google], Studio.auth_methods
    refute Studio.auth_method?(:wallet), "the hub must declare no wallet identity"
    assert Studio.auth_method?(:magic_link)
    assert Studio.auth_method?(:google)
  end

  # The property that makes this a REMOVAL and not a cosmetic change. Asserted on
  # the route set, not on any view's text.
  test "no Solana auth route is drawn" do
    WALLET_ROUTES.each do |path, verb|
      assert_raises ActionController::RoutingError, "#{verb.upcase} #{path} must not route" do
        Rails.application.routes.recognize_path(path, method: verb)
      end
    end
  end

  # The subtle one, and why it is not in the loop above. The PATH still matches
  # the hub's generic OmniAuth wildcard (GET /auth/:provider/callback), which is
  # drawn BEFORE Studio.routes and therefore SHADOWED the engine's phantom
  # callback even while :wallet was declared. So /auth/phantom/callback was never
  # reachable by path in this app — only by helper. The fallthrough is inert, not
  # a 500: OmniauthCallbacksController#create rescues the absent auth hash and
  # redirects to login.
  #
  # DOCUMENTATION, NOT A GUARD — measured: this test passes with :wallet declared
  # AND undeclared, so it does not discriminate on the change it sits beside. The
  # biting assertion for the phantom callback is `phantom_callback_path` in
  # "the Solana route helpers are undefined" below, which a re-declaration kills.
  # Kept because the shadow is non-obvious and cost a wrong assertion to find.
  test "the phantom callback no longer reaches the wallet controller" do
    route = Rails.application.routes.recognize_path("/auth/phantom/callback", method: :get)

    refute_equal "solana_sessions", route[:controller],
                 "the engine's wallet callback handler must be unreachable"
    assert_equal "omniauth_callbacks", route[:controller]
  end

  test "the Solana route helpers are undefined" do
    helpers = Rails.application.routes.url_helpers
    %i[solana_nonce_path solana_verify_path phantom_callback_path].each do |helper|
      refute helpers.respond_to?(helper),
             "#{helper} must be gone — a view or test calling it would raise NoMethodError"
    end
  end

  # The other half of the gate: dropping :wallet must not take magic-link with it.
  test "the magic-link route survives the drop" do
    assert_equal "/magic_link", Rails.application.routes.url_helpers.magic_link_request_path
  end

  # STILL HERE, but its reason is spent. It was kept because the signing console
  # identified signers by it; that console was retired on 2026-09-04
  # (/tasks/retire-signing-console) and nothing reads the column now. The drop is
  # its own task — /tasks/drop-hub-wallet-column — because it also takes the
  # parked admin wallets, the nav and admin-table chips, and an irreversible
  # migration against the live users table. Pinned until then so the column's
  # removal is a decision rather than a side effect.
  test "User#solana_address is retained" do
    assert_includes User.column_names, "solana_address"
  end
end
