# frozen_string_literal: true

require "test_helper"

# [integration] The first-name ask — this app's adoption of the engine's shared
# onboarding step (studio-engine 0.46.0).
#
# What is THIS app's to get right, and therefore what this file covers:
#
#   1. The endpoints are actually drawn here. They are opt-in in the engine
#      (turf-monster owns both helper names until its own adoption lands), so a
#      missing config.draw_onboarding_routes means a modal that 404s on save
#      with nothing else failing.
#   2. The modal is armed ONLY when the server says the name is still
#      outstanding — not for an account that already answered, and not again in
#      a session that skipped.
#   3. The write lands on the column the standard defines.
#
# The step's own markup and rules are the engine's (its suites cover the
# partial, the dedupe of endpoints, and Studio.first_name_outstanding?); this
# file does not re-test the gem.
class OnboardingFirstNameTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:viewer)
    @user.update_columns(first_name: nil)
  end

  # The MARKER the layout renders while the ask is outstanding — not the script.
  #
  # The script is now emitted on every page and attaches once per document; what
  # varies per page is this marker, which the handler reads at fire time. That is
  # the fix for a real bug: handlers live on `document` and survive a Turbo body
  # replacement, so keying "is the user asked?" on the SCRIPT's presence meant an
  # earlier page's handler kept re-asking on later pages that render no arming
  # block at all. Asserting the marker asserts the thing the browser actually
  # consults.
  ARM = %(id="onboarding-ask-first-name")

  # --- 1. the endpoints exist HERE --------------------------------------------

  test "this app draws the engine onboarding endpoints" do
    # Opt-in in the engine. Without the flag these helpers do not exist, and the
    # partial posts to a 404 while every other test still passes.
    assert_equal "/onboarding/first_name", onboarding_first_name_path
    assert_equal "/onboarding/skip_first_name", onboarding_skip_first_name_path
  end

  test "the endpoints reject a signed-out visitor" do
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json

    assert_not_equal 200, response.status,
      "an anonymous POST must not write a first name"
  end

  # --- 2. armed only when outstanding -----------------------------------------

  test "a signed-in account with no first name is asked" do
    log_in_as(@user)
    get root_path

    assert_response :success
    assert_includes response.body, ARM, "the modal must be opened, not merely registered"
  end

  test "an account that already answered is NOT asked again" do
    @user.update_columns(first_name: "Viewer")
    log_in_as(@user)
    get root_path

    assert_response :success
    assert_not_includes response.body, ARM
  end

  test "a signed-out visitor is not asked" do
    get root_path

    assert_response :success
    assert_not_includes response.body, ARM
  end

  test "skipping stops the ask for THIS session only" do
    log_in_as(@user)
    post onboarding_skip_first_name_path, as: :json

    assert_response :success
    get root_path
    assert_not_includes response.body, ARM, "skipped means not now"

    # A LATER session asks again — the field is still blank, which is the whole
    # reason the skip is session-scoped rather than a column.
    reset!
    log_in_as(@user)
    get root_path
    assert_includes response.body, ARM, "a new session asks again"
  end

  # --- 3. the write ------------------------------------------------------------

  test "saving a first name writes the standard column" do
    log_in_as(@user)
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json

    assert_response :success
    assert_equal true, response.parsed_body["ok"]
    assert_equal "Alex", @user.reload.first_name
  end

  test "the ask stops once the name is saved" do
    log_in_as(@user)
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json
    get root_path

    assert_not_includes response.body, ARM
  end

  test "a blank submission is refused and nothing is written" do
    log_in_as(@user)
    post onboarding_first_name_path, params: { first_name: "   " }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.first_name
  end

  test "this app reports no further steps after the name" do
    # It sets no onboarding_steps_resolver, so the engine default applies. turf
    # walks welcome → name → age → wallet; here the name is the only ask, and a
    # non-empty list would send the client looking for a step that does not exist.
    log_in_as(@user)
    post onboarding_first_name_path, params: { first_name: "Alex" }, as: :json

    assert_equal [], response.parsed_body["next"]
  end
end
