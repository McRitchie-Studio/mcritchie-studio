# frozen_string_literal: true

require "test_helper"

# [integration] The request-level half of dropping :wallet from the hub's
# config.auth_methods. The config + route-table half is the unit test at
# test/lib/wallet_auth_declaration_test.rb.
#
# The risk of this change was never the config line — it was the assumption that
# the admin signing console rode on wallet sign-in. It did not: the console was
# `require_admin` only and drove Phantom in the SIGNER'S OWN BROWSER, so the
# server held no key and read no wallet session. That console was DELETED on
# 2026-09-04 (/tasks/retire-signing-console), so only the sign-in half still has
# a subject here; the removal itself is pinned by
# test/integration/signing_console_retired_test.rb.
class WalletAuthDroppedTest < ActionDispatch::IntegrationTest
  test "the sign-in page paints no wallet CTA" do
    get signin_path
    assert_response :success
    refute_match "wallet-connect", response.body,
                 "the Connect Wallet picker modal must not be registered"
    refute_match "/auth/solana", response.body,
                 "the dead sign-in fetches must be gone from the layout"
    assert_match "Email Link", response.body, "magic-link sign-in must survive"
  end

  # The admin surface this file used to pin — the signing console surviving on a
  # magic-link session — is GONE as of 2026-09-04
  # (/tasks/retire-signing-console): Turf Monster is the hub for all web3, so the
  # hub keeps no console to reach. Its removal is pinned by
  # test/integration/signing_console_retired_test.rb. What remains here is the
  # half that still has a subject: the sign-in page itself.
  #
  # An ADMIN session is still worth walking, because dropping :wallet must not
  # have cost the admin surfaces that never depended on it.
  test "the admin dashboard is reachable on a magic-link session" do
    admin = users(:alex)

    log_in_as(admin)

    get admin_dashboard_path
    assert_response :success, "admin pages must not depend on wallet sign-in"
  end
end
