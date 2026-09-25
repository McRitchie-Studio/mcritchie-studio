require "test_helper"

# [component] The epic view's partials in isolation: the /epics row
# (epics/_epic_row), the /epics/<slug> header (epics/_epic_header), and the epic
# chips the /deployments release card now carries (tasks/_release_summary).
class EpicPartialsViewTest < ActionView::TestCase
  include ApplicationHelper

  def summary(**overrides)
    EpicSummary.new(**{
      slug: "devops-v3", counts_by_stage: { "building" => 1, "shipped" => 2, "designed" => 1 },
      done_count: 2, first_created_at: 4.days.ago, last_activity_at: 2.hours.ago, last_shipped_at: 1.day.ago
    }.merge(overrides))
  end

  test "[component] the row links to the epic and shows stage counts in board order" do
    render partial: "epics/epic_row", locals: { epic: summary }

    assert_select "[data-test='epic-row'][data-epic='devops-v3']"
    assert_select "a[data-test='epic-row-link'][href='/epics/devops-v3']", text: "devops-v3"
    stages = css_select("[data-test='epic-stage-count']").map { |el| el["data-stage"] }
    assert_equal %w[designed building shipped], stages
    assert_select "[data-test='epic-stage-count'][data-stage='shipped']", text: /Shipped\s*2/
    assert_includes rendered, "4 tasks"
  end

  test "[component] the row's done bar reports done over total" do
    render partial: "epics/epic_row", locals: { epic: summary }

    assert_select "[data-test='epic-progress'][data-done='2'][data-total='4']", text: %r{2/4 done}
    assert_select "[role='progressbar'][aria-valuenow='50']"
    assert_includes rendered, "width: 50%;"
    assert_select "[data-test='epic-row-activity']", text: /started 4d ago · last activity 2h ago/
  end

  test "[component] the header shows the span from first task to last ship" do
    render partial: "epics/epic_header", locals: { epic: summary(first_created_at: 4.days.ago, last_shipped_at: 1.day.ago) }

    assert_select "[data-test='epic-header'] h1", text: "devops-v3"
    assert_select "[data-test='epic-header-elapsed']", text: /3 days from first task to last ship/
    assert_select "a[href='/tasks?epic=devops-v3']", text: "Tasks board"
    assert_select "a[href='/deployments?epic=devops-v3']", text: "Deployments board"
    assert_select "[data-test='epic-header-capped']", 0, "no cap note when every task is drawn"
  end

  test "[component] an epic with nothing shipped says so instead of a span" do
    render partial: "epics/epic_header", locals: { epic: summary(done_count: 0, last_shipped_at: nil) }

    assert_select "[data-test='epic-header-elapsed']", text: /nothing shipped yet/
  end

  test "[component] a capped epic page says how many of its tasks are drawn" do
    render partial: "epics/epic_header", locals: { epic: summary, drawn_count: 3 }

    assert_select "[data-test='epic-header-capped']", text: /3 most recently updated of 4/
  end

  test "[component] the release card shows one chip per distinct epic its members carry" do
    rel = Release.open!(branch: "release/epic-chips")
    add_member(rel, "devops-v3")
    add_member(rel, "devops-v3")
    add_member(rel, "board-polish")
    add_member(rel, nil)

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    chips = css_select("[data-test='release-epics'] [data-test='task-epic-chip']").map { |el| el["data-epic"] }
    assert_equal %w[devops-v3 board-polish], chips
  end

  test "[component] a release with no epic members renders no epics row" do
    rel = Release.open!(branch: "release/no-epics")
    add_member(rel, nil)

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    assert_select "[data-test='release-epics']", 0
  end

  def add_member(rel, epic)
    @position = @position.to_i + 10
    Task.create!(title: "release epic member #{SecureRandom.hex(2)}", stage: "reviewed", position: @position,
                 release_slug: rel.slug, epic_slug: epic, metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
  end
end
