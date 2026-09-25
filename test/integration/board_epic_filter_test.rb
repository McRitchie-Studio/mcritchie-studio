require "test_helper"
# Rails 8.1 defers turbo-rails' on_load(:action_cable) hook, which is what
# normally requires this helper, so load it explicitly before the include below.
require "turbo/broadcastable/test_helper"

# [integration] the epic chip on BOTH render paths of the live card — the full
# page (/tasks and /deployments) and the turbo-stream push DeploymentsBroadcaster
# sends — and the `?epic=<slug>` filter the chip links to, on both boards.
#
# A live partial renders from two paths, and a chip that shows on one and not the
# other is the defect Shannon's checklist names; so both are asserted, not one.
class BoardEpicFilterTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  setup do
    @member = Task.create!(title: "Epic member board task", stage: "building", epic_slug: "devops-v3")
    @other = Task.create!(title: "Epic other board task", stage: "building", epic_slug: "other-epic")
    @plain = Task.create!(title: "Epic plain board task", stage: "building")
  end

  # --- render path 1: the full page --------------------------------------------

  test "[integration] /tasks renders the epic chip on a card with an epic and none on a card without" do
    get tasks_path
    assert_response :success

    assert_select "#card-#{@member.slug} [data-test='task-epic-chip'][href='/tasks?epic=devops-v3']", text: "devops-v3"
    assert_select "#card-#{@plain.slug} [data-test='task-epic-chip']", count: 0
    assert_select "[data-test='board-epic-filter']", { count: 0 }, "no banner on the unfiltered board"
  end

  test "[integration] /deployments renders the epic chip too" do
    @member.update!(stage: "reviewed")

    get deployments_path
    assert_response :success

    assert_select "#card-#{@member.slug} [data-test='task-epic-chip'][href='/tasks?epic=devops-v3']", text: "devops-v3"
  end

  # --- render path 2: the turbo-stream push ------------------------------------

  test "[integration] the broadcast card carries the epic chip" do
    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.approval_change(@member) }

    assert_equal 1, streams.size
    assert_equal "card-#{@member.slug}", streams.first["target"]
    html = streams.first.to_html
    assert_includes html, "data-test=\"task-epic-chip\"", "the live re-render must wear the chip the page render wears"
    assert_includes html, "/tasks?epic=devops-v3"
  end

  test "[integration] the broadcast card of a no-epic task carries no chip" do
    streams = capture_turbo_stream_broadcasts("deployments") { DeploymentsBroadcaster.approval_change(@plain) }

    assert_equal 1, streams.size
    refute_includes streams.first.to_html, "task-epic-chip"
  end

  # --- the filter the chip links to --------------------------------------------

  test "[integration] /tasks?epic= shows only that epic's cards and a banner with the way back" do
    get tasks_path(epic: "devops-v3")
    assert_response :success

    assert_select "#card-#{@member.slug}", 1
    assert_select "#card-#{@other.slug}", count: 0
    assert_select "#card-#{@plain.slug}", count: 0
    assert_select "[data-test='board-epic-filter'][data-epic='devops-v3'] [data-test='task-epic-chip']", text: "devops-v3"
    assert_select "[data-test='board-epic-filter'] a[data-test='board-epic-filter-clear'][href='/tasks']"
  end

  test "[integration] the filter matches through the same normalization the write used" do
    get tasks_path(epic: " DevOps-V3 ")
    assert_response :success

    assert_select "#card-#{@member.slug}", 1
    assert_select "#card-#{@other.slug}", count: 0
    assert_select "[data-test='board-epic-filter'][data-epic='devops-v3']", 1
  end

  test "[integration] /deployments?epic= honours the same param with the way back pointing at /deployments" do
    @member.update!(stage: "reviewed")
    @other.update!(stage: "reviewed")

    get deployments_path(epic: "devops-v3")
    assert_response :success

    assert_select "#card-#{@member.slug}", 1
    assert_select "#card-#{@other.slug}", count: 0
    assert_select "[data-test='board-epic-filter'] a[data-test='board-epic-filter-clear'][href='/deployments']"
  end

  # A filter that resolved to "everything" would read as a working filter.
  test "[integration] an epic nothing carries narrows the board to nothing, not to everything" do
    get tasks_path(epic: "no-such-epic")
    assert_response :success

    assert_select "#card-#{@member.slug}", count: 0
    assert_select "#card-#{@plain.slug}", count: 0
    assert_select "[data-test='board-epic-filter'][data-epic='no-such-epic']", 1
  end

  test "[integration] the epic filter composes with the stage filter" do
    @other.update!(epic_slug: "devops-v3", stage: "designed")

    get tasks_path(epic: "devops-v3", stage: "building")
    assert_response :success

    assert_select "#card-#{@member.slug}", 1
    assert_select "#card-#{@other.slug}", count: 0
  end
end
