require "test_helper"

# Integration: the Last Release card carries what the ReleaseFx router needs to
# decide whether ANYTHING should animate, and /deployments ships the router itself.
#
# THE BUG THIS CLOSES. Every finished assembling CI test flashed the Last Release
# card — pop, lift, glow, confetti. DeploymentsBroadcaster.ci_progress re-broadcast
# both release cards on every CI upsert; Release.last_shipped cannot change on a CI
# tick; so the client received byte-identical HTML with no declared reason and no
# signature to diff, and its fallback was to celebrate. The card now self-describes
# its identity (data-card-signature), which is the evidence the router needs to tell
# a real change from a redraw.
class LastReleaseFxRouterTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  test "[component] the Last Release card publishes the signature the router diffs" do
    Release.open!.ship!(by: "test")

    get deployments_path
    assert_response :success

    assert_select "#last-release[data-card-signature]" do |cards|
      assert cards.first["data-card-signature"].present?,
             "an empty signature would read as a change against every other render"
    end
  end

  test "[component] the signature MOVES when the shipped release does" do
    first = Release.open!
    first.ship!(by: "test")
    get deployments_path
    before = css_select("#last-release").first["data-card-signature"]

    second = Release.open!
    second.ship!(by: "test")
    get deployments_path
    after = css_select("#last-release").first["data-card-signature"]

    refute_equal before, after, "a different release in the slot must read as a change"
    assert_includes after, second.slug
  end

  test "[component] the signature HOLDS across a redraw that changed nothing" do
    Release.open!.ship!(by: "test")

    get deployments_path
    first = css_select("#last-release").first["data-card-signature"]
    get deployments_path
    second = css_select("#last-release").first["data-card-signature"]

    assert_equal first, second,
                 "the byte-identical re-render — the CI tick case — must produce an identical signature"
  end

  test "[component] the empty state declares a signature too, so the slot swap still reads" do
    get deployments_path
    assert_response :success

    # (count:, then the message — a bare String second arg is assert_select's
    # EXPECTED TEXT, not a failure message.)
    assert_select "#last-release[data-card-signature='none']", { count: 1 },
                  "with nothing shipped the slot still names itself, or swapping INTO a release reads as no change"
  end

  test "[component] /deployments loads the router module" do
    get deployments_path
    assert_response :success

    # The router is the board/release_fx_dom module, installed by board/live_fx_dom;
    # its default of silence is held by test/javascript/release_fx_test.js and
    # e2e/last_release_fx_router.spec.js.
    assert_select "script[type=module]", text: %r{import "board/live_fx_dom"}, count: 1
    importmap = css_select("script[type=importmap]").first&.text.to_s
    assert_includes importmap, %("board/release_fx_dom"), "the router module is pinned"
  end

  test "[component] the board publishes the beat its exits are timed to" do
    get deployments_path
    assert_response :success

    # Rendered from Release::BOARD_FLIP_CADENCE; e2e/deployments_exit_fx.spec.js reads
    # it here instead of restating it.
    assert_select "[data-test=kanban-board][data-beat-ms=?]", (Release::BOARD_FLIP_CADENCE * 1000).round.to_s, count: 1
  end
end
