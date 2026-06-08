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
end
