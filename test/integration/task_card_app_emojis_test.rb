require "test_helper"

# Component tier (ui-only shape): render the real board + current-release
# partials through their controllers and assert the new app-emoji indicators,
# the single-line title, and the slug row.
class TaskCardAppEmojisTest < ActionDispatch::IntegrationTest
  test "kanban card renders a single-line title and a slug row with affected-app emojis" do
    task = Task.create!(
      title: "board card title sample",
      stage: "building",
      metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio", "studio-engine"] } }
    )

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}" do
      # Feature 1: the title is a single-line truncate, no longer a 2-line clamp.
      assert_select "a[href=?]", task_path(task.slug) do |links|
        klass = links.first["class"].to_s
        assert_includes klass, "truncate"
        assert_not_includes klass, "line-clamp-2"
      end

      # Feature 3: the slug is shown, with the affected-app emojis grouped under
      # a title attribute listing the repos.
      assert_select "code", text: task.slug
      assert_select "span[title=?]", "mcritchie-studio, studio-engine"
    end

    assert_includes response.body, "🧰" # mcritchie-studio
    assert_includes response.body, "💎" # studio-engine
  end

  test "current-release member pills show app emojis in place of the stage badge" do
    member = Task.create!(
      title: "release member pill task",
      stage: "reviewed",
      metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio", "studio-engine"] } }
    )
    release = Release.open!(branch: "release/2026-emoji-test")
    release.add(member)
    release.assemble!
    release.ship!(by: "alex")

    get deployments_path
    assert_response :success

    assert_select "#current-release" do
      assert_select "a[href=?]", task_path(member.slug) do
        # Feature 2: app emojis ride the pill...
        assert_select "span[title=?]", "mcritchie-studio, studio-engine"
        # ...the old bold STAGE badge ("Shipped") is gone; the one bold chip on
        # the pill now is the deploy-target indicator, not a stage label.
        assert_select "span.font-bold", text: "mcritchie-studio → QA"
        assert_select "span.font-bold", { text: /shipped/i, count: 0 }
      end
    end
  end
end
