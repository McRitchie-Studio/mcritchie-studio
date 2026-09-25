require "test_helper"

# [integration] The epic view end to end: /epics lists every epic with its counts
# by stage, /epics/<slug> draws that epic's tasks on the board's own card grouped
# by stage, the board links reach /epics, and the conductor's release notes nest a
# release's tasks under their epics.
class EpicsPagesTest < ActionDispatch::IntegrationTest
  setup do
    @building = Task.create!(title: "Epic page building task", stage: "building", epic_slug: "devops-v3")
    @shipped = Task.create!(title: "Epic page shipped task", stage: "shipped", epic_slug: "devops-v3")
    @other = Task.create!(title: "Epic page other task", stage: "designed", epic_slug: "board-polish")
    @plain = Task.create!(title: "Epic page plain task", stage: "building")
  end

  test "[integration] /epics lists each epic with its counts by stage, signed out" do
    get epics_path
    assert_response :success

    assert_select "[data-test='epic-row'][data-epic='devops-v3']" do
      assert_select "a[href='/epics/devops-v3']", text: "devops-v3"
      assert_select "[data-test='epic-stage-count'][data-stage='building']", text: /1/
      assert_select "[data-test='epic-stage-count'][data-stage='shipped']", text: /1/
      assert_select "[data-test='epic-progress'][data-done='1'][data-total='2']"
    end
    assert_select "[data-test='epic-row'][data-epic='board-polish']"
    assert_select "a[data-test='board-link-epics'][aria-current='page']"
  end

  test "[integration] /epics/<slug> groups the epic's tasks by stage on the board card" do
    get epic_path("devops-v3")
    assert_response :success

    assert_select "[data-test='epic-header'][data-epic='devops-v3']"
    assert_select "[data-test='epic-stage'][data-stage='building'] #card-#{@building.slug}"
    assert_select "[data-test='epic-stage'][data-stage='shipped'] #card-#{@shipped.slug}"
    # The board's card, so the epic chip rides along.
    assert_select "#card-#{@building.slug} [data-test='task-epic-chip'][data-epic='devops-v3']"
    assert_select "#card-#{@other.slug}", 0, "another epic's task is not drawn"
    assert_select "#card-#{@plain.slug}", 0, "a task with no epic is not drawn"
    stages = css_select("[data-test='epic-stage']").map { |el| el["data-stage"] }
    assert_equal %w[building shipped], stages, "board order, empty stages skipped"
  end

  test "[integration] the epic page normalizes the handle like the board filter" do
    get "/epics/DevOps-V3"
    assert_response :success
    assert_select "[data-test='epic-header'][data-epic='devops-v3']"
  end

  test "[integration] an epic no task carries is a 404" do
    get epic_path("no-such-epic")
    assert_response :not_found
  end

  test "[integration] both boards link to /epics" do
    get tasks_path
    assert_select "a[data-test='board-link-epics'][href='/epics']"
    get deployments_path
    assert_select "a[data-test='board-link-epics'][href='/epics']"
  end

  test "[integration] the conductor's release notes nest a release's tasks under their epic" do
    rel = Release.open!(branch: "release/epic-notes")
    [@building, @plain].each_with_index do |task, index|
      task.update!(release_slug: rel.slug, position: (index + 1) * 10,
                   metadata: task.metadata.merge("devops" => { "repositories" => ["mcritchie-studio"] }))
    end

    message = Release::Conductor.post_release_notes(release: rel.reload, dry_run: true)[:message]

    assert_includes message, "🪎 McRitchie Studio\n• [Epic page plain task]"
    assert_includes message, "\n🧩 devops-v3\n  • [Epic page building task](https://mcritchie.studio/tasks/#{@building.slug})"
  end
end
