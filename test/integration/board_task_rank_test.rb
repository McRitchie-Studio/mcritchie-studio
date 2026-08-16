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
    # The WAITING APPROVAL bar is ONE full-length CTA that links to the mint endpoint
    # (a fresh single-use magic link per click), NOT the raw local_url.
    assert_select "#card-#{waiting.slug} a[data-test='operator-approval-waiting'][href='#{local_review_task_path(waiting.slug)}']",
                  text: "WAITING APPROVAL"
    bar = css_select("#card-#{waiting.slug} a[data-test='operator-approval-waiting']").first
    assert_equal "http://localhost:3001/demo", bar["data-local-url"], "the raw local_url rides along as a data-fallback"
  end

  test "[integration] submitted approval-exit card no longer waits for approval" do
    task = Task.create!(
      title: "approval exit peer",
      stage: "building",
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3001/demo"
        }
      }
    )
    task.submit!

    get tasks_path
    assert_response :success

    assert_includes card_order_in("dropzone-submitted"), "card-#{task.slug}"
    assert_select "#card-#{task.slug} [data-test='operator-approval-waiting']", count: 0
  end

  test "[integration] submitted PR cards no longer show a waiting-review bar" do
    task = Task.create!(
      title: "submitted review peer",
      stage: "submitted",
      metadata: { "devops" => { "pr_url" => "https://github.com/acme/app/pull/42" } }
    )

    get tasks_path
    assert_response :success

    # Dropped as redundant — the CI meter below links the PR; no shortcut lost.
    assert_select "#card-#{task.slug} [data-test='review-waiting']", count: 0
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

  # A SHIPPED BATCH LANDS IN THE ORDER IT LEFT, WHICH REVERSES IT — and that is the
  # deliberate consequence of the two rules either side of the move:
  #
  #   · Release#ship! flips members from the TOP of the Assembled column down
  #     (Task.ordered), because that is what an operator watches — the column peels
  #     from the top, one card per beat, rather than emptying upward.
  #   · Every stage move stamps position = column max + 100 and the live board
  #     prepends the arrival, so the LAST card to flip takes the top of Shipped.
  #
  # First to leave, therefore last in the column. This test used to assert the
  # opposite (the batch keeping its shape), which cannot hold at the same time as a
  # top-down departure while arrivals prepend; the operator chose the departure
  # (/tasks/stagger-board-exit-animations). The invariant that DOES survive is the
  # one asserted below and re-asserted live in e2e/release_ship.spec.js: the rank the
  # flips stamp and the order the live board shows are the same order, so a reload
  # never reshuffles the column under the operator.
  test "[integration] a shipped batch rests in the reverse of its assembled order" do
    release = Release.open!
    older_member = Task.create!(title: "older release member card", stage: "reviewed", created_at: 20.minutes.ago)
    newer_member = Task.create!(title: "newer release member card", stage: "reviewed", created_at: 5.minutes.ago)
    release.add(older_member)
    release.add(newer_member)
    release.assemble!
    # Ranked as the board renders them: newer on top, so it is the first to flip.
    older_member.update_column(:position, 100)
    newer_member.update_column(:position, 300)

    release.ship!(by: "avi")

    get deployments_path
    assert_response :success

    order = card_order_in("dropzone-shipped")
    assert_operator order.index("card-#{older_member.slug}"), :<, order.index("card-#{newer_member.slug}"),
                    "the member that flipped LAST holds the top of Shipped — first out, last in the column"
    assert_operator older_member.reload.position, :>, newer_member.reload.position,
                    "and the persisted rank says the same thing, so a reload can't reorder the column"
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
