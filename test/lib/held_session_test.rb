# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "time"
require_relative "../../bin/lib/held_session"

# [unit] The logins a harness session can present outside bin/task: the desk's
# studio login and the admin login, each read only by the harness session that
# logged in, and matched by soul before a caller that records an actor presents one.
class HeldSessionTest < Minitest::Test
  HARNESS = "harness-one"
  FUTURE = "2999-01-01T00:00:00Z"

  def with_dirs
    Dir.mktmpdir do |proj|
      Dir.mktmpdir do |desk|
        FileUtils.mkdir_p(File.join(desk, ".git"))
        yield proj, desk
      end
    end
  end

  def env(proj, extra = {}) = { "CLAUDE_PROJECTS_DIR" => proj, "CLAUDE_CODE_SESSION_ID" => HARNESS }.merge(extra)

  def keep_desk(desk, owner: HARNESS, expires_at: FUTURE, token: "DESK-TOKEN")
    DeskSession.write(desk, { "slug" => "sess-desk", "soul" => "pokemon", "tier" => "studio", "task_slug" => "a-task",
                              "expires_at" => expires_at, "token" => token, "harness_session_id" => owner })
  end

  def keep_admin(proj, soul: "xan", session: HARNESS, expires_at: FUTURE)
    AdminLogin.write(session, proj, { "soul" => soul, "session" => "sess-admin", "token" => "ADMIN-TOKEN",
                                      "expires_at" => expires_at }, env: { "CLAUDE_PROJECTS_DIR" => proj })
  end

  def find(proj, desk, **options) = HeldSession.find(env: env(proj), projects_dir: proj, cwd: desk, **options)

  def test_unit_no_login_is_held_by_default
    with_dirs { |proj, desk| assert_nil find(proj, desk) }
  end

  def test_unit_the_desks_login_is_offered_ahead_of_the_admin_login
    with_dirs do |proj, desk|
      keep_desk(desk)
      keep_admin(proj)

      assert_equal %w[DESK-TOKEN studio pokemon sess-desk], find(proj, desk).values_at("token", "tier", "soul", "slug")
      assert_equal "ADMIN-TOKEN", find(proj, desk, tier: "admin")["token"]
      assert_equal "ADMIN-TOKEN", find(proj, desk, soul: "xan")["token"]
      assert_equal "DESK-TOKEN", find(proj, desk, soul: "pokemon")["token"]
    end
  end

  def test_unit_a_soul_with_no_matching_login_gets_none
    with_dirs do |proj, desk|
      keep_desk(desk)
      keep_admin(proj, soul: "steffon")

      assert_nil find(proj, desk, soul: "carl"), "another agent of the same harness borrows no login"
      assert_nil find(proj, desk, soul: "xan")
    end
  end

  def test_unit_only_the_harness_session_that_logged_in_reads_a_login
    with_dirs do |proj, desk|
      keep_desk(desk, owner: "another-harness")
      keep_admin(proj, session: "another-harness")
      assert_nil find(proj, desk)

      # A run that names no harness session proves nothing.
      assert_nil HeldSession.find(env: { "CLAUDE_PROJECTS_DIR" => proj }, projects_dir: proj, cwd: desk)
      # Control: the owner reads both.
      assert_equal 2, HeldSession.all(env: env(proj).merge("CLAUDE_CODE_SESSION_ID" => "another-harness"),
                                      projects_dir: proj, cwd: desk).size
    end
  end

  def test_unit_an_expired_or_dropped_login_is_not_held
    with_dirs do |proj, desk|
      keep_desk(desk, expires_at: (Time.now - 60).utc.iso8601)
      keep_admin(proj, expires_at: (Time.now - 60).utc.iso8601)
      assert_nil find(proj, desk)

      keep_desk(desk)
      DeskSession.drop(desk)
      assert_nil find(proj, desk)
    end
  end

  def test_unit_the_hub_shell_grant_is_an_admin_login_whose_soul_is_unknown
    with_dirs do |proj, desk|
      login = HeldSession.find(env: env(proj, "AGENT_ADMIN_SESSION_TOKEN" => "ENV-ADMIN"), projects_dir: proj, cwd: desk, tier: "admin")

      assert_equal ["ENV-ADMIN", "admin", nil], login.values_at("token", "tier", "soul")
      assert_nil HeldSession.find(env: env(proj, "AGENT_ADMIN_SESSION_TOKEN" => "ENV-ADMIN"), projects_dir: proj, cwd: desk, soul: "xan"),
                 "a login of unknown soul never answers for a named one"
    end
  end

  def test_unit_an_explicit_session_id_wins_over_the_environment
    with_dirs do |proj, desk|
      keep_admin(proj, session: "from-the-hook-payload")

      assert_equal "ADMIN-TOKEN", HeldSession.find(env: { "CLAUDE_PROJECTS_DIR" => proj }, projects_dir: proj, cwd: desk,
                                                   session_id: "from-the-hook-payload")["token"]
    end
  end

  def test_unit_a_sandboxed_process_never_presents_a_login_kept_in_a_real_checkout
    real = File.expand_path("../..", __dir__)
    armed = { TaskUsageSandbox::ENV_KEY => "1" }

    assert HeldSession.sandboxed_away?(real, armed)
    refute HeldSession.sandboxed_away?(real, { TaskUsageSandbox::ENV_KEY => "0" })
    Dir.mktmpdir { |tmp| refute HeldSession.sandboxed_away?(tmp, armed), "a tmpdir desk is the test's own" }
  end
end
