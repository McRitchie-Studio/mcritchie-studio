# frozen_string_literal: true

require "test_helper"

# [integration] The request-level half of dropping :wallet from the hub's
# config.auth_methods. The config + route-table half is the unit test at
# test/lib/wallet_auth_declaration_test.rb.
#
# The risk of this change was never the config line — it was the assumption that
# the admin signing console rode on wallet sign-in. It does not: the console is
# `require_admin` only and drives Phantom in the SIGNER'S OWN BROWSER, so the
# server holds no key and reads no wallet session. Both halves are pinned here.
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

  # THE point of the task. log_in_as mints a magic link — there is no wallet
  # anywhere in this flow, and the fixture user carries no solana_address, so a
  # pass cannot be credited to one.
  test "the admin signing console is reachable on a magic-link session" do
    admin = users(:alex)
    assert_nil admin.solana_address,
               "fixture must have no wallet, so reachability cannot be credited to one"

    log_in_as(admin)

    get admin_signing_requests_path
    assert_response :success, "the console queue must not depend on wallet sign-in"

    get new_admin_signing_request_path
    assert_response :success, "the console builder must not depend on wallet sign-in"
  end

  # The console's admin wall is what gates it — not an auth METHOD. Pinned so a
  # future reader does not conclude the wall came from wallet sign-in.
  test "the signing console is gated by admin, not by any wallet identity" do
    get admin_signing_requests_path
    assert_response :redirect, "signed-out must not reach the console"

    log_in_as(users(:viewer))
    get admin_signing_requests_path
    assert_redirected_to root_path, "a non-admin magic-link session must be bounced"
  end
end
