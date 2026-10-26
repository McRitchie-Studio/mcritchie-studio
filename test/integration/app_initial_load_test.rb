require "test_helper"
require_relative "../support/client_cto_fixtures"

# [integration] The app's initial load (task build-sign-in-modal, Alex McRitchie
# 2026-10-19): a newly launched app (AppCto launch_animation_pending) plays the
# launch panel on its OWNER's first visit to /applications/:slug/chat and clears
# the flag as it renders, so a refresh is the chat. An admin reading someone
# else's app sees the chat and leaves the flag alone; Turbo's hover prefetch
# gets an empty answer and spends nothing.
class AppInitialLoadTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures

  setup do
    @owner = User.create!(email: "pat@example.test", name: "Pat Owner", role: "viewer")
    @client_app = client_app!
    AppMembership.create!(app: @client_app, user: @owner)
    @cto = @client_app.client_cto
    @cto.update!(launch_animation_pending: true)
  end

  def panel_count = css_select("[data-test='build-launch-landing'] build-launch[data-app='pawsome']").size

  test "the owner's first visit plays the launch panel once; the next is the chat" do
    log_in_as @owner
    get chat_application_path("pawsome")
    assert_response :success
    assert_equal 1, panel_count
    assert_select "build-launch[data-href='/applications/pawsome/chat'] [data-test='build-launch-step']", 3
    assert_select "[data-test='cto-chat-page']", 0
    assert_not @cto.reload.launch_animation_pending?

    get chat_application_path("pawsome")
    assert_equal 0, panel_count
    assert_select "[data-test='cto-chat-page'][data-app='pawsome']", 1
  end

  test "an admin viewing someone else's app sees the chat and leaves the owner's first visit alone" do
    log_in_as users(:alex)
    get chat_application_path("pawsome")
    assert_response :success
    assert_equal 0, panel_count
    assert_select "[data-test='cto-chat-page'][data-app='pawsome']", 1
    assert @cto.reload.launch_animation_pending?

    log_in_as @owner
    get chat_application_path("pawsome")
    assert_equal 1, panel_count, "still the owner's to see"
  end

  test "a Turbo prefetch of the chat spends nothing" do
    log_in_as @owner
    get chat_application_path("pawsome"), headers: { "X-Sec-Purpose" => "prefetch" }
    assert_response :no_content
    assert @cto.reload.launch_animation_pending?

    get chat_application_path("pawsome")
    assert_equal 1, panel_count
  end

  test "an app without the flag is the chat from the first visit" do
    @cto.update!(launch_animation_pending: false)
    log_in_as @owner
    get chat_application_path("pawsome")
    assert_equal 0, panel_count
    assert_select "[data-test='cto-chat-page'][data-app='pawsome']", 1
  end
end
