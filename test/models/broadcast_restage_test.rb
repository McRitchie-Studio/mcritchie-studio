require "test_helper"

# [unit] Broadcast#restage! (task tiered-your-games-copy): a copy fix reaches
# the emails still held. Every `staged` row is re-rendered with the current
# subject and template; approved, sent, cancelled and skipped rows are never
# touched, and nothing is sent.
class BroadcastRestageTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @broadcast = Broadcast.create!(slug: "your-games-restage", template_key: "cyvasse_your_games",
                                   target_list: "cyvasse-legacy",
                                   subject: "%{username}, your %{games} Cyvasse games are still here")
    @rows = %w[staged approved sent cancelled skipped].index_with do |status|
      contact = Contact.create!(email: "#{status}@example.com", tags: [ "cyvasse-legacy" ],
                                traits: { "cyvasse" => { "username" => status.capitalize, "games" => 1 } })
      @broadcast.staged_emails.create!(contact: contact, status: status, email: contact.email,
                                       delivery_token: "tok-#{status}", rendered_subject: "Old subject",
                                       rendered_html: "<p>Old body</p>", staged_at: 2.days.ago)
    end
  end

  test "re-renders staged rows with the current copy and leaves every other status alone" do
    before = @rows.except("staged").transform_values { |row| row.reload.attributes }
    result = nil
    assert_no_emails { assert_no_enqueued_jobs { result = @broadcast.restage! } }

    assert_equal 1, result.restaged
    assert_equal 0, result.skipped
    staged = @rows["staged"].reload
    assert staged.staged?
    assert_equal "Staged, your Cyvasse account is still here", staged.rendered_subject
    assert_includes staged.rendered_html, "Cyvasse Night"
    assert_equal "tok-staged", staged.delivery_token, "the row keeps its token, so its links still match"

    @rows.except("staged").each do |status, row|
      assert_equal before[status], row.reload.attributes, "a #{status} row must not change"
    end
  end

  test "a staged reader who has since lost a required field is skipped with the reason" do
    @rows["staged"].contact.update!(traits: {})
    result = @broadcast.restage!
    assert_equal 1, result.skipped
    assert_equal "missing username, games", @rows["staged"].reload.skip_reason
  end

  test "a row approved after the run read it keeps its approval and snapshot" do
    staged_id = @rows["staged"].id
    approved = false
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql]
      # Fire on the batch read of staged rows, before the per-row lock.
      next if approved || sql !~ /FROM "staged_emails" WHERE .*"status"/ || sql.include?("FOR UPDATE")

      approved = true
      # Another session approves the row after the run read it as staged.
      StagedEmail.connection.exec_update("UPDATE staged_emails SET status = 'approved' WHERE id = #{staged_id}")
    end
    result = @broadcast.restage!
    assert approved, "the race never ran, so this test proved nothing"
    assert_equal 1, result.left
    assert_equal 0, result.restaged
    row = StagedEmail.find(staged_id)
    assert_equal "approved", row.status
    assert_equal "Old subject", row.rendered_subject
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
