require "test_helper"

# [component] The live deployments partial ships the CSS the board effects toggle and
# loads the effects module. The behaviour itself is held elsewhere: the decisions and
# shapes by node:test (test/javascript/live_fx_test.js, release_fx_test.js), and the
# effects on a live board by Playwright (e2e/deployments_live.spec.js,
# deployments_exit_fx.spec.js, last_release_fx_router.spec.js, release_ship.spec.js).
class DeploymentsLiveFxTest < ActionView::TestCase
  test "the partial loads the live effects module" do
    render partial: "tasks/deployments_live_fx"

    assert_select "script[type=module]", text: %r{import "board/live_fx_dom"}, count: 1
  end

  test "confetti sits under a lifted card" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-confetti-active .kanban-card { position: relative; z-index: 30; }"
    assert_includes rendered, ".lbfx-card-front { position: relative; z-index: 40; }"
  end

  test "stage glow cards fade the live flash into their steady border shine" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-glow.lbfx-glow-stage { animation-name: lbfxGlowToStage; }"
    assert_includes rendered, "box-shadow: var(--task-card-glow-shadow);"
    assert_includes rendered, "border-color: var(--task-card-glow-border-color);"
  end

  # Rendered through _deployments_live_fx on purpose: the router's CSS is rendered BY
  # that partial, so this also proves the two halves of the fx layer ship together.
  test "the fresh deploy glow holds to the knee, then fades onto the resting card" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, "animation: lbfxFreshDeployGlow 60.0s linear both"
    # The knee: held to 80% of the window, then eased out. Rendered from
    # FRESH_DEPLOY_HOLD_FRACTION, so the card body, ring and halo cannot drift apart.
    assert_equal 3, rendered.scan("0%, 80.0%").size
    # The fade LANDS on the resting card: opacity .75 and the theme's own border token.
    assert_includes rendered, "opacity: .75;"
    assert_includes rendered, "border-color: var(--color-border, transparent);"
  end

  test "every fresh-glow CSS duration renders from the injectable window" do
    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      render partial: "tasks/deployments_live_fx"

      assert_includes rendered, "animation: lbfxFreshDeployGlow 20.0s linear both"
      assert_includes rendered, "animation-duration: var(--studio-border-glow-duration, 20s), 20.0s;"
      assert_includes rendered, "animation: lbfxFreshDeployRingFade 20.0s linear both"
      assert_includes rendered, "animation: lbfxFreshDeployHaloFade 20.0s linear both"
      # No default-window duration survives an override.
      assert_no_match(/[\s,(]60(\.0)?s[;\s,]/, rendered)
    end
  end

  test "a ticked meter rings at meter scale, and keeps its bloom" do
    render partial: "tasks/deployments_live_fx"

    # The engine's 4px/10px defaults are drawn for a card and swamp an 18px bar. The
    # bloom is kept: a ring-only cut was built and compared on screen.
    assert_includes rendered, "--studio-team-glow-thickness: 2px"
    assert_includes rendered, "--studio-team-glow-bloom: 4px"
    assert_not_includes rendered, ".release-meter-glow::after { content: none; }"
  end
end
