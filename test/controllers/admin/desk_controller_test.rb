require "test_helper"

# [integration] /admin/desk — admin-gated, lists arrivals with status chips,
# filters by status, and says plainly when the desk is clear.
class Admin::DeskControllerTest < ActionDispatch::IntegrationTest
  def admin
    @admin ||= User.find_by(role: "admin") ||
               User.create!(email: "desk-admin@example.com", name: "Desk Admin", role: "admin")
  end

  test "anonymous and non-admin visitors are turned away" do
    get admin_desk_path
    assert_response :redirect

    member = User.create!(email: "desk-member@example.com", name: "Member")
    log_in_as(member)
    get admin_desk_path
    assert_response :redirect
  end

  test "admin sees arrivals with status chips and entity hints" do
    DeskCaptureItem.create!(s3_key: "incoming/aaa", status: "received",
                            from_addr: "amcritchie@gmail.com",
                            subject: "[welding] Site visit transcript",
                            entity_hint: "commercial-welding-llc",
                            received_at: Time.current,
                            attachments: [ { "filename" => "t.txt", "s3_key" => "parsed/aaa/0-t.txt",
                                             "content_type" => "text/plain", "byte_size" => 9 } ])
    DeskCaptureItem.create!(s3_key: "incoming/bbb", status: "quarantined",
                            from_addr: "stranger@example.com", subject: "hello",
                            received_at: 1.hour.ago)

    log_in_as(admin)
    get admin_desk_path
    assert_response :success
    assert_includes response.body, "desk-items"
    assert_includes response.body, "commercial-welding-llc"
    assert_includes response.body, "desk-status-quarantined"

    get admin_desk_path(status: "quarantined")
    assert_response :success
    assert_includes response.body, "stranger@example.com"
    refute_includes response.body, "amcritchie@gmail.com"
  end

  test "an empty desk says so" do
    log_in_as(admin)
    get admin_desk_path
    assert_response :success
    assert_includes response.body, "desk-empty"
  end

  test "the page names team@ as the front door, never desk@" do
    log_in_as(admin)
    get admin_desk_path
    assert_response :success
    assert_includes response.body, "team@mcritchie.studio"
    refute_includes response.body, "desk@mcritchie.studio"
  end
end
