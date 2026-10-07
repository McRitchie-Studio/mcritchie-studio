require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/desk_session").to_s

# [unit] DeskSession: which requests take the desk's session token, whose harness
# may present it, and which slug a request names once the token is no longer offered.
class DeskSessionTest < ActiveSupport::TestCase
  OWNER = "harness-builder".freeze

  test "only a write naming a task is a task write" do
    assert_equal "t-1", DeskSession.task_slug_for(:patch, "/api/v1/tasks/t-1")
    assert_equal "t-1", DeskSession.task_slug_for(:post, "/api/v1/tasks/t-1/events/building/start")
    assert_nil DeskSession.task_slug_for(:get, "/api/v1/tasks/t-1")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/tasks/claim_next_review")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/tasks")
    assert_nil DeskSession.task_slug_for(:post, "/api/v1/activities")
  end

  test "the token is offered for its own task until shortly before it expires" do
    with_root do |root, now|
      FileUtils.mkdir_p(File.join(root, "app"))
      assert_equal File.realpath(root), File.realpath(DeskSession.root_for(File.join(root, "app")))
      assert_equal "tok", DeskSession.token_for("t-1", root: root, harness_session_id: OWNER, now: now)
      assert_nil DeskSession.token_for("t-2", root: root, harness_session_id: OWNER, now: now)
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: OWNER, now: now + 3600 - 30)

      DeskSession.clear(root)
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: OWNER, now: now)
    end
  end

  # The owner guard: a reviewer (or any other harness) running bin/task inside the
  # builder's desk must not borrow the builder's login.
  test "the token is withheld from a harness other than the one that opened it" do
    with_root do |root, now|
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: "harness-reviewer", now: now)
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: nil, now: now)
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: "", now: now)
    end
  end

  test "a session file that names no harness is offered to nobody" do
    with_root(harness_session_id: nil) do |root, now|
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: OWNER, now: now)
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: nil, now: now)
    end
  end

  test "a dropped session keeps its slug, and the owner's later writes name it" do
    with_root do |root, now|
      assert_nil DeskSession.dropped_slug_for("t-1", root: root, harness_session_id: OWNER, now: now)

      DeskSession.drop(root)

      refute_includes File.read(DeskSession.path(root)), "tok", "a dropped session keeps no token"
      assert_nil DeskSession.token_for("t-1", root: root, harness_session_id: OWNER, now: now)
      assert_equal "sess-1", DeskSession.dropped_slug_for("t-1", root: root, harness_session_id: OWNER, now: now)
      assert_nil DeskSession.dropped_slug_for("t-2", root: root, harness_session_id: OWNER, now: now)
      assert_nil DeskSession.dropped_slug_for("t-1", root: root, harness_session_id: "harness-reviewer", now: now)
    end
  end

  test "an expired session names its slug on the fallback too" do
    with_root do |root, now|
      assert_equal "sess-1", DeskSession.dropped_slug_for("t-1", root: root, harness_session_id: OWNER, now: now + 7200)
    end
  end

  private

  def with_root(harness_session_id: OWNER)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      now = Time.now
      DeskSession.write(root, { "slug" => "sess-1", "task_slug" => "t-1", "token" => "tok",
                                "expires_at" => (now + 3600).utc.iso8601,
                                "harness_session_id" => harness_session_id }.compact)
      yield root, now
    end
  end
end
