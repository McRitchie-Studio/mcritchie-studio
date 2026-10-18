require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] The Forget button on /admin/agent_messages/:id's notes panel: admin
# only, a DELETE form post (CSRF-guarded), and it removes that one note.
class Admin::AgentPersonNotesControllerTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  setup do
    @message = agent_message!(soul: "ray", channel: "discord", author_ref: "500", author_name: "Alex")
    @notes = AgentPersonNote.record_from!(@message, [ "Favorite color is purple.", "Runs the hub." ])
  end

  def admin
    @admin ||= User.find_by(role: "admin") || User.create!(email: "notes-admin@example.com", name: "Notes Admin", role: "admin")
  end

  test "anonymous and non-admin visitors cannot forget a note" do
    delete admin_agent_person_note_path(@notes.first, message_id: @message.id)
    assert_response :redirect
    log_in_as(User.create!(email: "notes-member@example.com", name: "Member"))
    delete admin_agent_person_note_path(@notes.first, message_id: @message.id)
    assert_response :redirect
    assert_equal 2, AgentPersonNote.count
  end

  test "the message page shows a Forget form per note, and it deletes that note and returns to the message" do
    log_in_as(admin)
    get admin_agent_message_path(@message)
    assert_select "form[action=?] button#am-forget-#{@notes.first.id}",
                  admin_agent_person_note_path(@notes.first, message_id: @message.id)
    assert_select "form[action=?] input[name=_method][value=delete]",
                  admin_agent_person_note_path(@notes.first, message_id: @message.id)

    delete admin_agent_person_note_path(@notes.first, message_id: @message.id)
    assert_redirected_to admin_agent_message_path(@message)
    assert_equal [ "Runs the hub." ], @message.person.notes.map(&:body)
  end

  test "the form is CSRF-guarded: a post without a token is refused when forgery protection is on" do
    log_in_as(admin)
    ActionController::Base.allow_forgery_protection = true
    delete admin_agent_person_note_path(@notes.first, message_id: @message.id)
    assert_includes [ 403, 422 ], response.status
    assert_equal 2, AgentPersonNote.count
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
