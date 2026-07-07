require "test_helper"

# Integration tier: the board renders each stage column newest-on-top. The
# event-driven rank (Task#ordered → position DESC; a create/stage-move stamps
# max + 100) puts the freshest card first on BOTH boards.
class BoardTaskRankTest < ActionDispatch::IntegrationTest
  test "deployments column lists the newest task in a stage first" do
    older  = Task.create!(title: "rank older designed card", stage: "designed")
    newer  = Task.create!(title: "rank newer designed card", stage: "designed")
    # newer is created last → higher position → must render above older.

    get deployments_path
    assert_response :success

    order = card_order_in("dropzone-designed")
    assert_operator order.index("card-#{newer.slug}"), :<, order.index("card-#{older.slug}"),
                    "the newer task should render above the older one"
  end

  test "tasks board shares the newest-on-top order" do
    older = Task.create!(title: "rank older building card", stage: "building")
    newer = Task.create!(title: "rank newer building card", stage: "building")

    get tasks_path
    assert_response :success

    order = card_order_in("dropzone-building")
    assert_operator order.index("card-#{newer.slug}"), :<, order.index("card-#{older.slug}"),
                    "the same shared `ordered` scope drives the build board too"
  end

  test "[integration] tasks waiting for approval rank above stage peers" do
    normal = Task.create!(title: "normal building peer", stage: "building", position: 10_000)
    waiting = Task.create!(
      title: "approval waiting peer",
      stage: "building",
      position: 100,
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3001/demo"
        }
      }
    )

    get tasks_path
    assert_response :success

    order = card_order_in("dropzone-building")
    assert_operator order.index("card-#{waiting.slug}"), :<, order.index("card-#{normal.slug}"),
                    "operator approval requests should float to the top of the stage list"
    assert_select "#card-#{waiting.slug} [data-test='operator-approval-waiting']", text: "WAITING APPROVAL"
    assert_select "#card-#{waiting.slug} [data-test='local-demo-button']", text: "Local Demo"
  end

  test "[integration] deployments column puts freshly shipped tasks above older shipped cards" do
    older = nil
    fresh = nil

    travel_to 2.hours.ago do
      older = Task.create!(title: "older shipped board card", stage: "shipped")
    end
    travel_to 10.minutes.ago do
      fresh = Task.create!(title: "fresh assembled board card", stage: "assembled")
    end
    travel_to Time.current do
      fresh.ship!
    end

    get deployments_path
    assert_response :success

    order = card_order_in("dropzone-shipped")
    assert_operator order.index("card-#{fresh.slug}"), :<, order.index("card-#{older.slug}"),
                    "a card that just entered shipped should render above older shipped work"
  end

  test "[integration] release ship ranks newly shipped members newest first on reload" do
    release = Release.open!
    older_member = Task.create!(title: "older release member card", stage: "reviewed", created_at: 20.minutes.ago)
    newer_member = Task.create!(title: "newer release member card", stage: "reviewed", created_at: 5.minutes.ago)
    release.add(older_member)
    release.add(newer_member)
    release.assemble!

    release.association(:tasks).target = [newer_member.reload, older_member.reload]
    release.association(:tasks).loaded!
    release.ship!(by: "avi")

    get deployments_path
    assert_response :success

    order = card_order_in("dropzone-shipped")
    assert_operator order.index("card-#{newer_member.slug}"), :<, order.index("card-#{older_member.slug}"),
                    "a deployment batch should not render newer shipped members below older members"
  end

  private

  # Card element ids within a dropzone, top → bottom.
  def card_order_in(dropzone_id)
    doc = Nokogiri::HTML(@response.body)
    zone = doc.at_css("##{dropzone_id}")
    assert zone, "dropzone ##{dropzone_id} should render"
    zone.css(".kanban-card").map { |el| el["id"] }
  end
end
