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
    assert_includes rendered, "card.dataset.freshDeployCleanup === \"true\""
    assert_includes rendered, "card.classList.remove(\"opacity-75\")"
    assert_includes rendered, "card.classList.add(\"studio-border-glow\", \"release-fresh-glow\")"
    assert_includes rendered, "card.dataset.freshDeployCleanup = \"true\""
    assert_includes rendered, "freshDeployGlow(fresh)"
    assert_includes rendered, "clearFreshDeployGlow(card)"
    assert_includes rendered, "card.classList.remove(\"lbfx-fresh-deploy\", \"studio-border-glow\", \"release-fresh-glow\")"
    assert_includes rendered, "card.classList.add(\"opacity-75\")"
    assert_includes rendered, "card.dataset.freshDeploy = \"false\""
    assert_includes rendered, "delete card.dataset.freshDeployCleanup"
    assert_includes rendered, "const FRESH_DEPLOY_STYLE_PROPS = ["
    assert_includes rendered, "\"--task-card-glow-shadow\""
    assert_includes rendered, "\"border-color\""
    assert_includes rendered, "\"box-shadow\""
    assert_includes rendered, "FRESH_DEPLOY_STYLE_PROPS.forEach((prop) => card.style.removeProperty(prop))"
    assert_includes rendered, "card.removeAttribute(\"style\")"
    assert_includes rendered, "function initializeFreshDeployGlows(root)"
    assert_includes rendered, "#last-release[data-fresh-deploy='true']"
    assert_includes rendered, "document.addEventListener(\"turbo:load\", scheduleFreshDeployGlowInitialization)"
    assert_includes rendered, "document.addEventListener(\"DOMContentLoaded\", scheduleFreshDeployGlowInitialization, { once: true })"
  end

  test "every fresh-glow duration renders from the injectable window" do
    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      render partial: "tasks/deployments_live_fx"

      # The JS cleanup timer and ALL four fresh-glow CSS durations move together —
      # a window where CSS and JS disagree would fade the glow at one time and
      # flip the state at another.
      assert_includes rendered, "const FRESH_DEPLOY_MS = 20000"
      assert_includes rendered, "animation: lbfxFreshDeployGlow 20.0s linear both"
      assert_includes rendered, "animation-duration: var(--studio-border-glow-duration, 20s), 20.0s;"
      assert_includes rendered, "animation: lbfxFreshDeployRingFade 20.0s linear both"
      assert_includes rendered, "animation: lbfxFreshDeployHaloFade 20.0s linear both"
      # The property, not the spellings: NO default-window duration survives an
      # override — a leftover hardcoded 8s would re-open the race the override
      # exists to close. (The regex spares unrelated sub-second values like .8s.)
      assert_no_match(/[\s,(]8s[;\s,]/, rendered)
      assert_not_includes rendered, "= 8000"
    end
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

  test "a ticked meter rings itself instead of flashing the whole Next Release card" do
    render partial: "tasks/deployments_live_fx"

    # ORDER is the load-bearing part: the old signatures are read BEFORE renderNow()
    # replaces the slot. Read them after and the previous values are already gone —
    # every meter would look unchanged and the card would flash on every CI tick.
    assert_match(/const before = RELEASE_FX\[target\][\s\S]{0,200}const renderNow = event\.detail\.render;/, rendered,
                 "the signature snapshot must be taken before the render is invoked")
    assert_includes rendered, "const moved = changedMeters(fresh, before && before.meters);"
    assert_includes rendered, "if (moved && moved.length) moved.forEach(meterGlow);"
    # THREE branches. The card flash is earned by the CARD's own signature moving — never
    # by the mere absence of a meter change, whose complement includes "nothing changed",
    # the byte-identical queued→in_progress re-render that flashed the card at nothing.
    assert_includes rendered,
                    "else if (!before || (fresh.dataset.cardSignature || \"\") !== before.card) glow(fresh);"
    assert_not_includes rendered, "else glow(fresh);",
                        "an unconditional else is the defective two-way branch — the card needs a reason"
    assert_includes rendered, "card: root ? (root.dataset.cardSignature || \"\") : \"\""
    # A changed lane-UP (a member added/dropped) is not a tick — it falls back to the card.
    assert_includes rendered, "if (!before || before.size !== after.length) return null;"

    # The ring itself: the engine's primitive on the BAR-sized glow host (not the meter
    # wrapper — that boxed the label in and read as a blob), tinted from the bar's OWN
    # fill so it can never disagree with the tone it traces, and gone in 2s.
    assert_includes rendered, ".release-meter-glow"
    assert_includes rendered, "meter.querySelector(\"[data-test='release-phase-glow-host']\") || meter"
    assert_includes rendered, "meter.querySelector(\"[data-test='release-phase-fill']\")"
    assert_includes rendered, "host.style.setProperty(\"--studio-team-glow-color\", color)"
    # The transparent-fill guard PAINTS the colour and reads the pixel's alpha.
    #
    # This tier can only assert the SHAPE of the source — it cannot run the JS, so it cannot
    # hold the property. Read the previous version of these lines as a warning: they forbade
    # ONE spelling of the rgba regex and asserted the canvas was constructed, and a guard
    # that still matched a differently-spelled rgba regex passed all of them while writing a
    # fully transparent colour to the knob. Enumerating spellings is not a guard.
    #
    # The property lives in e2e/deployments_live.spec.js ("a transparent modern-syntax tone
    # leaves the ring its default colour" / "an opaque modern-syntax tone still tints the
    # ring"), which drives a real oklch tone through this function in a browser and reads
    # the knob. Chromium serializes a computed colour back in the space it was authored in,
    # so an oklch or color-mix transparent tone never looks like rgba(..., 0).
    assert_includes rendered, "document.createElement(\"canvas\").getContext(\"2d\", { willReadFrequently: true })"
    assert_includes rendered, "ctx.getImageData(0, 0, 1, 1).data[3] === 0 ? null : value"
    assert_includes rendered, "const color = paintableColor("
    assert_no_match(/exec\(ctx\.fillStyle\)/, rendered,
                    "matching the serialized fillStyle asserts a spelling, not the alpha")
    assert_includes rendered, "host.classList.add(\"studio-team-glow\", \"release-meter-glow\")"
    assert_includes rendered, "host.classList.remove(\"studio-team-glow\", \"release-meter-glow\")"
    assert_includes rendered, "const METER_GLOW_MS = 2000"
    assert_includes rendered, "METER_GLOW_MS - METER_FADE_MS"
    # Meter scale, not card scale: the engine's 4px/10px defaults are drawn for a card and
    # swamp an 18px bar. The bloom is KEPT — a ring-only cut was built and compared on
    # screen, and this is the one that reads.
    assert_includes rendered, "--studio-team-glow-thickness: 2px"
    assert_includes rendered, "--studio-team-glow-bloom: 4px"
    assert_not_includes rendered, ".release-meter-glow::after { content: none; }",
                        "the bloom is a deliberate choice, not an oversight — don't re-drop ::after"
  end

  test "[component] a moving card slides off to the right and fades" do
    render partial: "tasks/deployments_live_fx"

    assert_includes rendered, "const SLIDE_OFF_RIGHT"
    assert_includes rendered, "transform: \"translateX(150px) scale(.95)\""
    assert_includes rendered, "const SLIDE_OFF_MS = 300"
    # Opacity falls WITH the travel rather than ahead of it: a front-loaded fade left
    # an invisible node still sliding while the arrival waited on it.
    assert_includes rendered, "{ opacity: 0.55, transform: \"translateX(58px) scale(.98)\", offset: 0.5 }"
    assert_not_includes rendered, "{ opacity: 0, transform: \"scale(.55)\" }",
                        "the shrink-in-place exit is what the slide-off replaced"
  end

  test "[component] every exit finishes inside its own beat" do
    render partial: "tasks/deployments_live_fx"

    # A batch flip moves one card per beat (Release::BOARD_FLIP_CADENCE = 0.8s). An
    # exit longer than the beat leaves two cards animating at once while the column
    # re-flows under both — measured on the live board at 760ms against a 500ms beat,
    # and the operator's word for the result was "not organized".
    assert_includes rendered, "const BEAT_MS = 800"
    assert_includes rendered, "const EXIT_MS = 400"
    assert_includes rendered, "const GAP_CLOSE_MS = 300"
    assert_includes rendered, "const GROW_IN_MS = 300"
    beat = rendered[/const BEAT_MS = (\d+)/, 1].to_i
    %w[EXIT_MS GAP_CLOSE_MS GROW_IN_MS].each do |name|
      duration = rendered[/const #{name} = (\d+)/, 1].to_i
      assert_operator duration, :<, beat, "#{name} must finish inside the beat"
    end
    # A MOVE is the LONGEST thing a beat has to hold: the outgoing slide, then the
    # arrival growing in at the far column. At a 400ms slide and a 380ms grow-in that
    # chain came to ~845ms and spilled onto the next card's departure.
    slide = rendered[/const SLIDE_OFF_MS = (\d+)/, 1].to_i
    grow  = rendered[/const GROW_IN_MS = (\d+)/, 1].to_i
    assert_operator slide + grow, :<=, beat,
                    "slide + grow-in must fit ONE beat, or an arrival lands on the next departure"
    # The durations are spelled through the constants, so a retimed beat can't leave
    # one exit path behind.
    assert_includes rendered, "{ duration: EXIT_MS, easing: \"ease-in\", fill: \"forwards\" }"
    assert_includes rendered, "\"transform \" + GAP_CLOSE_MS + \"ms linear\""
    # The old dissolve, spelled exactly — `duration: 760` alone also matches the
    # reviewed-ARRIVAL wake, which is not an exit and owes the beat nothing.
    assert_not_includes rendered, "{ duration: 760, easing: \"ease-in\", fill: \"forwards\" }",
                        "the 760ms dissolve outran the beat"
    assert_not_includes rendered, "transform .45s linear", "the 450ms gap-close outran it too"
  end

  test "[component] the move exit animates a scrubbed ghost, not the real card" do
    render partial: "tasks/deployments_live_fx"

    # The move payload re-uses the card's id for the incoming card, so the real
    # node must be removed on Turbo's schedule — the ghost carries the animation.
    assert_includes rendered, "function flyOutGhost(card, remove)"
    assert_includes rendered, "collapsing.set(target, flyOutGhost(document.getElementById(target), () => removeNow(el)))"
    assert_includes rendered, "card.cloneNode(true)"
    assert_includes rendered, "remove();"
    # Alpine initialises anything added to the document: a clone that kept its
    # directives would re-run them outside the board's scope, and its ids and
    # data-test hooks would double every selector while it lived.
    assert_includes rendered, "function scrubGhost(root)"
    assert_includes rendered, "el.removeAttribute(\"id\")"
    assert_includes rendered, "el.removeAttribute(\"data-test\")"
    assert_includes rendered, "/^(x-|@|:)/.test(attr.name)"
    assert_includes rendered, "ghost.dataset.test = \"card-fly-out\""
    # The hand-off WATCHES the ghost's opacity instead of scheduling off its duration.
    # A timer was tried twice and missed twice: keyframe offsets are progress-space,
    # a timer is wall-clock, and the easing between them is not the identity — the
    # arrival ended up waiting on a ghost that had been invisible for 165ms, which is
    # the "delay" an operator sees and a DOM-level measurement does not.
    assert_includes rendered, "const HANDOFF_OPACITY = 0.12"
    assert_includes rendered, "Number(getComputedStyle(ghost).opacity) <= HANDOFF_OPACITY"
    assert_not_includes rendered, "SLIDE_OFF_MS * HANDOFF_AT",
                        "a duration-fraction timer cannot know when the fade actually ended"
    # The column still closes the gap behind it, and reduced-motion skips straight
    # to the removal.
    assert_includes rendered, "flipSiblings(siblings, beforeTop)"
    assert_includes rendered, "if (!card || reducedMotion()) { remove(); return Promise.resolve(); }"
  end

  test "[component] the column stays positioned until the LAST card has finished leaving" do
    render partial: "tasks/deployments_live_fx"

    # An exiting card is absolutely positioned inside its column. A save/restore
    # pair let the first finisher yank that containing block away from every exit
    # still in flight — those cards jumped to the document's top-left corner. The
    # count is what makes overlapping exits (any batch) safe.
    assert_includes rendered, "const zoneExitHolds = new WeakMap()"
    assert_includes rendered, "function holdZonePositioned(zone)"
    assert_includes rendered, "function releaseZonePositioned(zone)"
    assert_includes rendered, "hold.count += 1"
    assert_includes rendered, "if (hold.count > 0) return;"
    assert_includes rendered, "zone.style.position = hold.restore"
    assert_not_includes rendered, "const restorePos = zone.style.position",
                        "the save/restore pair IS the bug — one finisher must not un-position the column"
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
