require "test_helper"

# [component] The rendered half of /tasks/drop-hub-wallet-column.
#
# Dropping users.solana_address took three chips with it: the truncated address
# in the navbar's progress bar, and the "wallet" pill in both the admin users
# table and the dashboard's user list. This pins that they are gone from the
# PAGES, which is a different claim from "the column is gone" (that one lives in
# test/lib/wallet_auth_declaration_test.rb) — a view can keep rendering a stale
# label long after the data behind it stops existing.
#
# EVERY TEST HERE CARRIES A POSITIVE CONTROL, because "the page does not contain
# the word wallet" is exactly the assertion that passes when the page failed to
# render at all. So each one first proves the surrounding region really painted —
# a google chip, the user's email, the level bar — and only then asserts the
# absence beside it.
class WalletChipsDroppedTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    # A google-linked row is the control: it proves the chip STRIP renders, so a
    # missing "wallet" pill means the pill is gone rather than the whole region.
    @admin.update!(provider: "google_oauth2", uid: "chip-control-1")
    log_in_as(@admin)
  end

  test "[component] the admin users table paints an auth chip but never a wallet one" do
    get admin_model_path("users")
    assert_response :success

    assert_includes response.body, ">google<", "the control chip must render, or this test proves nothing"
    assert_includes response.body, @admin.email, "the row for the signed-in admin must be on the page"

    refute_includes response.body, ">wallet<", "the users table still paints a wallet chip"
    refute_includes response.body, "No email or wallet", "the empty-cell copy still offers a wallet"
  end

  test "[component] the admin dashboard user list paints no wallet chip" do
    get admin_dashboard_path
    assert_response :success

    assert_includes response.body, ">google<", "the control chip must render, or this test proves nothing"
    refute_includes response.body, ">wallet<", "the dashboard user list still paints a wallet chip"
    refute_includes response.body, "No email or wallet", "the empty-cell copy still offers a wallet"
  end

  # The navbar's left slot is deliberately an EMPTY span holding the level
  # indicator's right edge (app/views/components/_user_nav.html.erb). Assert the
  # bar still renders, so deleting the span shows up here rather than as a
  # silently reflowed navbar nobody looks at.
  test "[component] the navbar renders its level bar with no address in it" do
    get root_path
    assert_response :success

    assert_includes response.body, "nav-bar-text",
      "the nav bar must still render, or the empty left slot proves nothing"
    refute_match(/[1-9A-HJ-NP-Za-km-z]{4}…[1-9A-HJ-NP-Za-km-z]{4}/, response.body,
                 "a truncated base58 address is still painted in the nav")
  end

  # The privacy page told visitors we collect a Solana wallet. We no longer can.
  test "[component] the privacy policy no longer claims a wallet sign-in route" do
    get privacy_path
    assert_response :success

    assert_includes response.body, "magic link", "the control: the auth sentence must still be on the page"
    refute_includes response.body, "Solana wallet", "privacy copy still offers wallet sign-in"
  end
end
