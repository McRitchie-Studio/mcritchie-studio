require "test_helper"

module ReleaseNotes
  class FormatterTest < ActiveSupport::TestCase
    test "formats production release notes grouped by application with production task links" do
      studio_task = tasks(:done_task)
      studio_task.update!(
        title: "Sidebar back-navigation production fix",
        metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
      )
      turf_task = tasks(:queued_task)
      turf_task.update!(
        title: "Contest settle button",
        metadata: { "devops" => { "repositories" => ["turf-monster"] } }
      )

      message = Formatter.new(
        app: "mcritchie-studio",
        environment: "production",
        release: "v71",
        sha: "ef693ab1abc",
        url: "https://mcritchie.studio/",
        release_train: "2026-06-18-devops-tooling",
        checks: ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
        tasks: [studio_task, turf_task]
      ).message

      assert_includes message, "🚀 Production deployed: McRitchie Studio v71 (ef693ab)"
      assert_includes message, "https://mcritchie.studio/\n\n🧰 McRitchie Studio"
      assert_includes message, "🧰 McRitchie Studio"
      assert_includes message, "• [Sidebar back-navigation production fix](https://mcritchie.studio/tasks/task-ddd444)"
      assert_includes message, "\n\n🐊 Turf Monster"
      assert_includes message, "• [Contest settle button](https://mcritchie.studio/tasks/task-bbb222)"
      assert_includes message, "💎 Studio Engine\n• No deployed tasks"
      assert_includes message, "\n\nChecks: production /up 200, /signin 200, /tasks 200, web + worker dynos running."
    end

    test "uses selected app group for tasks without repository metadata" do
      task = tasks(:failed_task)
      task.update!(title: "Mainnet vault proof", metadata: {})

      message = Formatter.new(
        app: "turf-vault",
        environment: "production",
        release: "v3",
        sha: "123456789",
        url: "https://turfmonster.media/",
        tasks: [task]
      ).message

      assert_includes message, "🏛️ Vault\n• [Mainnet vault proof](https://mcritchie.studio/tasks/task-eee555)"
    end
  end
end
