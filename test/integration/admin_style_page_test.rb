require "test_helper"

# [integration] Guards MS's adoption of studio-engine's living style guide.
# The engine bundles /admin/style (StyleController#index, helper admin_style_path)
# with four sections — Theme · Modals · Tricks · Tasks — and MS's admin sidebar
# links straight to it. This confirms the engine route resolves in the host app,
# renders for an admin, and stays admin-gated. It also pins the 0.25 Profile
# Leveling rebuild: the confetti/pulse tricks and the per-card leveling modal
# demos (change-username + join-newsletter), with MS's app :leveling flag OFF.
class AdminStylePageTest < ActionDispatch::IntegrationTest
  test "admin gets /admin/style with the Theme, Modals, Tricks and Tasks sections" do
    log_in_as users(:alex)

    get admin_style_path
    assert_response :success

    assert_select "#theme",  { count: 1 }, "expected the Theme section"
    assert_select "#modals", { count: 1 }, "expected the Modals section"
    assert_select "#tricks", { count: 1 }, "expected the Tricks section"
    assert_select "#tasks",  { count: 1 }, "expected the Tasks section"
  end

  # studio-engine 0.25 Profile Leveling rebuild: the confetti/pulse tricks (ported
  # from Turf Monster) and the rebuilt Profile Leveling modal demos. The old
  # `-plain` fork is gone — each demo is now ONE modal id (change-username +
  # join-newsletter) with a per-card runtime Leveling toggle, and the "updated"
  # cards reopen the same id at props.celebrate. MS still ships the app :leveling
  # flag OFF, so the Tricks leveling ladder stays present-but-flagged (disabled).
  test "admin/style shows the confetti/pulse tricks and the Profile Leveling modal demos" do
    log_in_as users(:alex)

    get admin_style_path
    assert_response :success

    # Confetti — the two window.studioConfetti entrypoints fire from specimen buttons.
    assert_includes @response.body, "window.studioConfetti.burst",
      "expected the studioConfetti.burst trick specimen"
    assert_includes @response.body, "window.studioConfetti.cannons()",
      "expected the studioConfetti.cannons trick specimen"
    # Pulse — the .pulse-cta attention beat renders as a real button.
    assert_select "button.pulse-cta", { minimum: 1 }, "expected a .pulse-cta specimen button"

    # App :leveling OFF for MS: the Tricks leveling ladder stays present-but-flagged.
    assert_not Studio.feature?(:leveling), "MS must ship leveling OFF for this spec"
    assert_includes @response.body, "disabled on this app",
      "expected the leveling trick group flagged disabled"

    # Profile Leveling section (rebuilt in 0.25): one modal id per activity, each
    # openable from its specimen card; the "updated" cards reopen the same id at
    # celebrate: true. The old `-plain` twin ids are gone.
    assert_includes @response.body, "Profile Leveling",
      "expected the Profile Leveling modal section"
    assert_includes @response.body, "$store.dsModals.open('change-username'",
      "expected the change-username modal demo to be openable"
    assert_includes @response.body, "$store.dsModals.open('join-newsletter'",
      "expected the join-newsletter modal demo to be openable"
    assert_includes @response.body,
      "$store.dsModals.open('change-username', { demo: true, leveling: opts.leveling, celebrate: true",
      "expected the updated Great Username card to reopen change-username at celebrate: true"

    # The removed leveling-off `-plain` fork must not resurface.
    assert_not_includes @response.body, "change-username-plain",
      "the removed -plain change-username demo must not resurface"
    assert_not_includes @response.body, "quest-activity-plain",
      "the removed -plain quest-activity demo must not resurface"
  end

  # studio-engine 0.27.0 adds the Web3 Contest + Contest-entry specimen flows to
  # the Modals section and renames two headings: "Web3" -> "Web3 Contest" and
  # "Eligibility & entry" -> "Contest entry & eligibility". This pins MS's
  # adoption: the renamed sections render (present-but-flagged even with :web3 /
  # :age_gate off), and the walked on-chain entry flow specimen is openable.
  test "admin/style renders the 0.27.0 Web3 Contest and Contest-entry sections" do
    log_in_as users(:alex)

    get admin_style_path
    assert_response :success

    # Renamed section headings (entity-decoded text match).
    assert_select "h3", { text: "Web3 Contest" },
      "expected the renamed Web3 Contest section heading"
    assert_select "h3", { text: "Contest entry & eligibility" },
      "expected the renamed Contest entry & eligibility section heading"

    # The old heading names must not resurface.
    assert_select "h3", { text: "Web3", count: 0 },
      "the pre-0.27.0 bare Web3 heading must not resurface"
    assert_select "h3", { text: "Eligibility & entry", count: 0 },
      "the pre-0.27.0 Eligibility & entry heading must not resurface"

    # The new walked on-chain entry flow specimen is present and openable.
    assert_includes @response.body, "$store.dsModals.open('onchain-tx'",
      "expected the Web3 Contest on-chain transaction flow specimen"
    assert_includes @response.body, "$store.dsModals.open('entry-confirmed'",
      "expected the Contest-entry confirmation flow specimen"
  end

  test "the admin sidebar Design System link points at /admin/style" do
    log_in_as users(:alex)

    get dashboard_path
    assert_response :success

    assert_select "#studio-link-sidebar a[href=?]", admin_style_path
    # It must not regress to the legacy design_system route (which only redirects).
    assert_select "#studio-link-sidebar a[href=?]", admin_design_system_path, count: 0
  end

  test "the canonical admin_style route resolves and /admin/design_system redirects to it" do
    assert_equal "/admin/style", admin_style_path

    get admin_design_system_path
    assert_redirected_to "/admin/style"
  end

  test "a non-admin cannot reach /admin/style" do
    log_in_as users(:viewer)

    get admin_style_path
    assert_response :redirect
  end
end
