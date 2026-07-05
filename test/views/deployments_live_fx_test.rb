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
end
