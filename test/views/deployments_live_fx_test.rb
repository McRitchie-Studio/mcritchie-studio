require "test_helper"

# [component] The live deployments animation partial owns the client-side visual
# layer for Turbo-Streamed board updates.
class DeploymentsLiveFxTest < ActionView::TestCase
  test "generate confetti renders behind the lifted card and starts from side edges" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-confetti-active .kanban-card"
    assert_includes rendered, ".lbfx-confetti-active .kanban-card.lbfx-card-front"
    assert_includes rendered, ".lbfx-card-front"
    assert_includes rendered, "z-index: 40"
    assert_includes rendered, "document.body.classList.add(\"lbfx-confetti-active\")"
    assert_includes rendered, "spawnConfettiBehind(card)"
    assert_includes rendered, "z-index:20"
    assert_includes rendered, "r.left + 3"
    assert_includes rendered, "r.right - 3"
    assert_includes rendered, "42 + Math.random() * 118"
    assert_not_includes rendered, "spawnBubbles"
    assert_not_includes rendered, "z-index:60"
  end

  test "stage glow cards fade the live flash into their steady border shine" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-glow.lbfx-glow-stage"
    assert_includes rendered, "@keyframes lbfxGlowToStage"
    assert_includes rendered, "box-shadow: var(--task-card-glow-shadow)"
    assert_includes rendered, "border-color: var(--task-card-glow-border-color)"
    assert_includes rendered, "function stageGlowHex(card)"
    assert_includes rendered, "!!card.dataset.stageGlow"
    assert_includes rendered, "card.classList.add(\"lbfx-glow-stage\")"
    assert_includes rendered, "card.classList.remove(\"lbfx-glow\", \"lbfx-glow-stage\")"
  end

  test "fresh deployments use an eight second rainbow glow that preserves phase" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-fresh-deploy"
    assert_includes rendered, ".release-fresh-glow.lbfx-fresh-deploy::before"
    assert_includes rendered, ".release-fresh-glow.lbfx-fresh-deploy::after"
    assert_includes rendered, "@keyframes lbfxFreshDeployGlow"
    assert_includes rendered, "@keyframes lbfxFreshDeployRingFade"
    assert_includes rendered, "@keyframes lbfxFreshDeployHaloFade"
    assert_includes rendered, "0%, 50%"
    assert_includes rendered, "--task-card-glow-shadow"
    assert_includes rendered, "--task-card-glow-border-color"
    assert_includes rendered, "const FRESH_DEPLOY_MS = 8000"
    assert_includes rendered, "card.dataset.freshDeploy !== \"true\""
    assert_includes rendered, "card.dataset.shippedAtMs"
    assert_includes rendered, "\"--lbfx-fresh-delay\""
    assert_includes rendered, "card.classList.remove(\"opacity-75\")"
    assert_includes rendered, "card.classList.add(\"studio-border-glow\", \"release-fresh-glow\")"
    assert_includes rendered, "freshDeployGlow(fresh)"
    assert_includes rendered, "clearFreshDeployGlow(card)"
    assert_includes rendered, "card.classList.remove(\"lbfx-fresh-deploy\", \"studio-border-glow\", \"release-fresh-glow\")"
    assert_includes rendered, "card.classList.add(\"opacity-75\")"
  end

  test "reviewed arrivals use a distinct behind-card gust" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, ".lbfx-reviewed-arrive"
    assert_includes rendered, ".lbfx-reviewed-swell"
    assert_includes rendered, "spawnReviewedGustBehind(card)"
    assert_includes rendered, "spawnReviewedWake(card)"
    assert_includes rendered, "REVIEWED_GUST_COLORS"
    assert_includes rendered, "card.dataset.stage === \"reviewed\""
    assert_includes rendered, "reviewedBurst(card, pop)"
  end

  test "archive removals can dissolve through the mist exit" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, "MIST_COLORS"
    assert_includes rendered, "spawnMist(card)"
    assert_includes rendered, "exitAction === \"archive\""
    assert_includes rendered, "stream.dataset.exitAction"
    assert_includes rendered, "filter: \"blur(9px)\""
    assert_includes rendered, "z-index:45"
  end
end
