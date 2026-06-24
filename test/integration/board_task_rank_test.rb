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

  private

  # Card element ids within a dropzone, top → bottom.
  def card_order_in(dropzone_id)
    doc = Nokogiri::HTML(@response.body)
    zone = doc.at_css("##{dropzone_id}")
    assert zone, "dropzone ##{dropzone_id} should render"
    zone.css(".kanban-card").map { |el| el["id"] }
  end
end
