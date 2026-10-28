require "test_helper"
require "rake"

# [unit] app_credentials:mint prints the secret once (and the row keeps only its
# digest), refuses an app the agent-chat allow-list does not name, and revoke ends it.
class AppCredentialsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("app_credentials:mint")
  end

  # The task's stdout; an abort's SystemExit is re-raised after the capture.
  def run_task(name, env)
    saved = env.keys.to_h { |k| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    Rake::Task[name].reenable
    exited = nil
    out, = capture_io do
      Rake::Task[name].invoke
    rescue SystemExit => e
      exited = e
    end
    raise exited if exited

    out
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  test "mint prints a working secret once and stores only its digest; revoke ends it" do
    out = run_task("app_credentials:mint", { "APP" => "alex-build", "BY" => "test" })
    secret = out.lines.last.strip

    assert_includes out, "apps.alex-build.agent-chat"
    row = AppCredential.authenticate(secret, purpose: "agent-chat")
    assert_equal "alex-build", row.app_slug
    refute_includes run_task("app_credentials:list", {}), secret, "list never shows a secret"

    run_task("app_credentials:revoke", { "APP" => "alex-build", "BY" => "test" })
    assert_nil AppCredential.authenticate(secret, purpose: "agent-chat")
  end

  test "mint refuses an app the allow-list does not name" do
    assert_raises(SystemExit) { run_task("app_credentials:mint", { "APP" => "not-listed" }) }
    assert_equal 0, AppCredential.count
  end
end
