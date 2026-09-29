require "test_helper"

class BroadcastsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @admin  = users(:alex)    # role: admin
    @viewer = users(:viewer)
    @broadcast = Broadcast.create!(subject: "Hi", template_key: "new_game_announcement",
                                   survivor_url: "https://x/sv", turf_totals_url: "https://x/tt")
    Contact.create!(email: "a@example.com", first_name: "A")
    Contact.create!(email: "b@example.com", first_name: "B")
    Contact.create!(email: "c@example.com", subscribed: false) # unsubscribed → suppressed
  end

  test "index requires admin" do
    get broadcasts_path
    assert_response :redirect # not logged in → login

    log_in_as(@viewer)
    get broadcasts_path
    assert_redirected_to root_path # non-admin bounced
  end

  test "admin can open the index" do
    log_in_as(@admin)
    get broadcasts_path
    assert_response :success
  end

  test "deliver queues a send job only for subscribed contacts and marks sent" do
    log_in_as(@admin)
    assert_enqueued_jobs 2, only: BroadcastSendJob do
      post deliver_broadcast_path(@broadcast), params: { audience: "all" }
    end
    assert @broadcast.reload.sent?
  end

  test "deliver blocks a duplicate send" do
    @broadcast.update!(status: "sent", sent_at: Time.current)
    log_in_as(@admin)
    assert_no_enqueued_jobs only: BroadcastSendJob do
      post deliver_broadcast_path(@broadcast), params: { audience: "all" }
    end
  end

  # [component] The Cyvasse relaunch note renders in the email shell with its
  # short live-matches copy, the new board header (alt text its own, not the
  # layout's old "World Cup"), the MS violet Play Now button to the landing
  # page and the app-builder P.S.
  test "the cyvasse_is_back preview renders its copy and links" do
    cyvasse = Broadcast.create!(slug: "cyvasse-is-back", subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    log_in_as(@admin)
    get preview_broadcast_path(cyvasse)

    assert_response :success
    assert_includes response.body, "Cyvasse is back"
    assert_select "img[src$='/email/cyvasse_header_live.jpg'][alt^='A Cyvasse board mid-game']"
    assert_not_includes response.body, "World Cup"
    assert_select "a[href='https://cyvasse.mcritchie.studio/']", text: /Play Now/
    assert_select "td[bgcolor='#8E82FE'] a", text: /Play Now/
    assert_select "a[href='https://mcritchie.studio/build']"
    assert_includes response.body, "Hi &#128075;&#127995;"
    assert_includes response.body, "<strong>live matches</strong>"
    assert_includes response.body, "<strong>leaderboard</strong>"
    assert_not_includes response.body, "100,000 matches", "the copy was cut to the live-matches pitch"
    assert_includes response.body, "because you have an account on Cyvasse"
    assert_not_includes response.body, "joined the McRitchie Studio mailing list"
  end

  test "a template that names no reason keeps the mailing-list footer" do
    log_in_as(@admin)
    get preview_broadcast_path(@broadcast)
    assert_includes response.body, "joined the McRitchie Studio mailing list"
  end
end
