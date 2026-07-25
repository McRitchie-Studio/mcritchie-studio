require "test_helper"

class ReleaseSummaryMembersTest < ActionDispatch::IntegrationTest
  test "[component] current release condenses member tasks into highlights plus repo counts" do
    Release.delete_all
    rel = Release.open!(branch: "release/condensed-members")
    small_studio = release_member_task("Small studio polish", po_size: "small", repo: "mcritchie-studio", position: 10)
    small_studio.task_events.create!(to_stage: "reviewed", occurred_at: Time.current, cost: BigDecimal("20.0"))
    large_studio = release_member_task("Large studio effort", po_size: "large", repo: "mcritchie-studio", position: 20)
    xl_turf = release_member_task("Expensive turf repair", actual_size: "xl", repo: "turf-monster", position: 30)
    medium_studio = release_member_task("Medium studio work", dev_size: "medium", repo: "mcritchie-studio", position: 40)
    medium_studio.task_events.create!(to_stage: "reviewed", occurred_at: Time.current, cost: BigDecimal("10.0"))
    small_turf = release_member_task("Small turf chore", po_size: "small", repo: "turf-monster", position: 50)

    [small_studio, large_studio, xl_turf, medium_studio, small_turf].each { |task| rel.add(task) }

    get deployments_path

    assert_response :success
    assert_select "#current-release [data-release-member='highlight']", 2
    assert_select "#current-release a[href=?][data-release-member='highlight']", task_path(small_studio.slug), text: /Small studio polish/
    assert_select "#current-release a[href=?][data-release-member='highlight']", task_path(medium_studio.slug), text: /Medium studio work/
    assert_select "#current-release a[data-release-member='highlight']" do |links|
      links.each do |link|
        assert_includes link["class"], "w-64"
        assert_includes link.to_html, "mask-image: linear-gradient(to right"
      end
    end
    assert_select "#current-release a[href=?][data-release-member='highlight'] [data-test='release-member-cost']",
                  task_path(small_studio.slug), text: "$20.00"
    assert_select "#current-release a[href=?][data-release-member='highlight'] [data-test='release-member-cost']",
                  task_path(medium_studio.slug), text: "$10.00"
    assert_select "#current-release [data-test='release-member-repo-count']", text: /· 🪎 1/
    assert_select "#current-release [data-test='release-member-repo-count']", text: /· 🐊 2/
    assert_select "#current-release", { text: /Expensive turf repair/, count: 0 }
    assert_select "#current-release", { text: /Large studio effort/, count: 0 }
    assert_select "#current-release", { text: /Small turf chore/, count: 0 }
  end

  private

  def release_member_task(title, repo:, position:, po_size: nil, dev_size: nil, actual_size: nil)
    Task.create!(title: title, stage: "reviewed", position: position,
                 po_size: po_size, dev_size: dev_size, actual_size: actual_size,
                 metadata: { "devops" => { "repositories" => [repo] } })
  end
end
