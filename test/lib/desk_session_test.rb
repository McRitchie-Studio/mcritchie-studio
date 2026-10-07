require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/desk_session").to_s

# [unit] DeskSession: which requests take the desk's session token, and when the
# stored token is no longer offered.
class DeskSessionTest < ActiveSupport::TestCase
  test "only a write naming a task is a task write" do
    assert_equal "t-1", DeskSession.task_slug_for(:patch, "/api/v1/tasks/t-1")
    assert_equal "t-1", DeskSession.task_slug_for(:post, "/api/v1/tasks/t-1/events/building/start")
    assert_nil DeskSession.task_slug_for(:get, "/api/v1/tasks/t-1")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/tasks/claim_next_review")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/tasks")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/activities")
  end

  test "the token is offered for its own task until shortly before it expires" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      now = Time.now
      DeskSession.write(root, "task_slug" => "t-1", "token" => "tok", "expires_at" => (now + 3600).utc.iso8601)

      FileUtils.mkdir_p(File.join(root, "app"))
      assert_equal File.realpath(root), File.realpath(DeskSession.root_for(File.join(root, "app")))
      assert_equal "tok", DeskSession.token_for("t-1", root: root, now: now)
      assert_nil DeskSession.token_for("t-2", root: root, now: now)
      assert_nil DeskSession.token_for("t-1", root: root, now: now + 3600 - 30)

      DeskSession.clear(root)
      assert_nil DeskSession.token_for("t-1", root: root, now: now)
    end
  end
end
