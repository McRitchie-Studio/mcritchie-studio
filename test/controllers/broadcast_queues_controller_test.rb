require "test_helper"

# [integration] /broadcasts/:slug/queue (task staged-email-queue): the admin
# gate, the page and its counters, the preview of the stored snapshot, and the
# approve → confirm → execute walk. Nothing here sends until execute.
class BroadcastQueuesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @broadcast = Broadcast.create!(slug: "queue-test", subject: "Hi %{first_name}", template_key: "cyvasse_is_back",
                                   target_list: "cyvasse-legacy")
    @ann = listed("ann@example.com", first_name: "Ann")
    @bob = listed("bob@example.com", first_name: "Bob")
    @anon = listed("anon@example.com") # no first name: skipped
  end

  def listed(email, **attrs)
    Contact.create!(email: email, tags: [ "cyvasse-legacy" ], **attrs).tap { _1.record_verification!(status: "valid") }
  end

  def row(contact) = @broadcast.staged_emails.find_by!(contact: contact)

  test "the queue is admin only" do
    get broadcast_queue_path(@broadcast)
    assert_response :redirect
    assert_not_equal broadcast_queue_path(@broadcast), URI(response.location).path

    log_in_as(@viewer)
    get broadcast_queue_path(@broadcast)
    assert_redirected_to root_path
    post stage_broadcast_queue_path(@broadcast)
    assert_redirected_to root_path
    assert_equal 0, StagedEmail.count, "a non-admin stages nothing"
  end

  test "staging from the page holds each email, sends nothing, and the page shows it" do
    log_in_as(@admin)
    assert_no_emails do
      assert_no_enqueued_jobs { post stage_broadcast_queue_path(@broadcast) }
    end
    assert_redirected_to broadcast_queue_path(@broadcast)
    follow_redirect!

    assert_select "h2", "Locked and loaded, not sent"
    assert_select "[data-count=staged] [data-count-value]", "2"
    assert_select "[data-count=skipped] [data-count-value]", "1"
    assert_select "[data-skip-reasons] li", /missing first_name/
    assert_select "[data-staged-row=#{row(@ann).id}]", /Hi Ann/
    assert_select "[data-staged-row=#{row(@ann).id}] a[href=?]", preview_broadcast_queue_path(@broadcast, email_id: row(@ann).id)
  end

  test "the index and the editor link to the queue" do
    log_in_as(@admin)
    get broadcasts_path
    assert_select "a[href=?]", broadcast_queue_path(@broadcast)
    get edit_broadcast_path(@broadcast)
    assert_select "a[href=?]", broadcast_queue_path(@broadcast)
  end

  test "preview renders the stored snapshot with tracking disarmed" do
    @broadcast.stage!
    ann = row(@ann)
    ann.update_columns(rendered_html: ann.rendered_html.sub("Cyvasse is back &mdash;", "SNAPSHOT-MARKER"))

    log_in_as(@admin)
    get preview_broadcast_queue_path(@broadcast, email_id: ann.id)
    assert_response :success
    assert_includes response.body, "SNAPSHOT-MARKER", "the preview is the stored email, not a fresh render"
    assert_not_includes response.body, "/e/o/"

    get preview_broadcast_queue_path(@broadcast, email_id: row(@anon).id)
    assert_response :not_found
  end

  test "approve, confirm and execute send only what was approved" do
    @broadcast.stage!
    log_in_as(@admin)

    post approve_broadcast_queue_path(@broadcast), params: { bulk: "1", ids: [ row(@ann).id ] }
    assert_equal %w[approved staged], [ row(@ann).status, row(@bob).status ]

    get broadcast_queue_path(@broadcast, confirm: "execute")
    assert_select "[data-confirm-execute] [data-confirm-count]", "1"
    assert_select "[data-confirm-execute]", /Bounce rate/

    assert_enqueued_jobs 1, only: BroadcastSendJob do
      post execute_broadcast_queue_path(@broadcast), params: { limit: 5 }
    end
    perform_enqueued_jobs(only: BroadcastSendJob)
    assert_equal "sent", row(@ann).status
    assert_equal "staged", row(@bob).status
  end

  test "execute on a paused gate sends nothing and says why" do
    @broadcast.stage!
    @broadcast.approve_staged!
    other = Broadcast.create!(subject: "Old", template_key: "cyvasse_is_back")
    other.deliveries.create!(contact: Contact.create!(email: "x@example.com"), sent_at: 1.hour.ago)
         .record_event!(kind: "bounced", source: "resend")

    log_in_as(@admin)
    get broadcast_queue_path(@broadcast, confirm: "execute")
    assert_select "[data-gate-reasons]", /bounce rate/
    assert_select "[data-confirm-execute] form", 0

    assert_no_enqueued_jobs { post execute_broadcast_queue_path(@broadcast), params: { limit: 5 } }
    assert_match(/Paused/, flash[:alert])
  end

  test "an empty bulk selection approves nothing, cancel and re-stage work on one row" do
    @broadcast.stage!
    log_in_as(@admin)
    post approve_broadcast_queue_path(@broadcast), params: { bulk: "1" }
    assert_equal 0, @broadcast.staged_emails.of_status("approved").count

    post cancel_broadcast_queue_path(@broadcast), params: { ids: [ row(@bob).id ] }
    assert_equal "cancelled", row(@bob).status

    post restage_broadcast_queue_path(@broadcast, email_id: row(@bob).id)
    assert_equal "staged", row(@bob).status
  end

  test "the editor's send refuses a personalized broadcast" do
    log_in_as(@admin)
    assert_no_enqueued_jobs { post deliver_broadcast_path(@broadcast), params: { audience: "cyvasse-legacy" } }
    assert_redirected_to broadcast_queue_path(@broadcast)

    get edit_broadcast_path(@broadcast)
    assert_select "input[type=submit][value='Send now']", count: 0
    assert_select "a[data-personalized-send][href=?]", broadcast_queue_path(@broadcast)

    plain = Broadcast.create!(slug: "plain", subject: "Hi", template_key: "cyvasse_is_back")
    get edit_broadcast_path(plain)
    assert_select "input[type=submit][value='Send now']", count: 1
  end
end
