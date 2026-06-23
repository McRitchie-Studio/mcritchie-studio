require "test_helper"

# Component tier (ui-only shape): render the real board + current-release
# partials through their controllers and assert the polished card behaviour —
# the full-width overflow-fade title, the data-driven app emoji, the footer
# actions, the whole-card click target, and the removal of the → QA chip.
class TaskCardAppEmojisTest < ActionDispatch::IntegrationTest
  test "kanban card: full-width title link, app emojis, footer actions, click target" do
    task = Task.create!(
      title: "board card title sample",
      stage: "building",
      metadata: { "devops" => { "kind" => "feature", "repositories" => ["mcritchie-studio", "studio-engine"] } }
    )

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}" do
      # Feature 6: the whole card is the click target (carries its destination).
      assert_select "[data-href=?]", task_path(task.slug)

      # Feature 1: the title is a single-line link carrying the task title (it
      # wraps the overflow-fade component instead of a 2-line clamp).
      assert_select "a[href=?]", task_path(task.slug) do |links|
        assert links.first.text.include?(task.title), "title link should carry the task title"
      end

      # Slug row: the slug shows with the affected-app emojis grouped under a
      # title attribute listing the repos.
      assert_select "code", text: task.slug
      assert_select "span[title=?]", "mcritchie-studio, studio-engine"

      # Feature 2: archive + delete moved to footer buttons (building shows both).
      assert_select "button[title=?]", "Archive"
      assert_select "button[title=?]", "Delete"
    end

    # Feature 4: the data-driven app emoji for mcritchie-studio is the new glyph.
    assert_includes response.body, "🪎" # mcritchie-studio
    assert_includes response.body, "💎" # studio-engine
    refute_includes response.body, "🧰" # the old mcritchie-studio glyph is gone
  end

  test "release member pills show app emojis and no deploy-target chip" do
    # A shipped release surfaces in the read-only Last Release section; member
    # pills render the same way there as in the Current section.
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

    assert_select "#last-release" do
      assert_select "a[href=?]", task_path(member.slug) do
        # Feature 5: app emojis ride the pill, and there is no bold chip — neither
        # the old stage badge ("Shipped") nor the removed deploy-target ("→ QA").
        assert_select "span[title=?]", "mcritchie-studio, studio-engine"
        assert_select "span.font-bold", false
      end
    end
    refute_includes response.body, "→ QA"
  end

  test "kanban card shows the Pokemon mascot chip" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1)
    task = Task.create!(
      title: "mascot chip card task",
      stage: "building",
      metadata: { "devops" => { "kind" => "feature", "mascot" => "snorlax" } }
    )

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}" do
      assert_select "img[src=?]", "/pokemon/143.png"
      assert_select "span", text: "Snorlax"
    end
  end
end
