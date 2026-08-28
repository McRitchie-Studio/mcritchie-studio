# frozen_string_literal: true

require "test_helper"

# [component] Adoption of studio-engine's shared layer scale.
#
# WHAT THIS HUB CONTRIBUTED TO THE AUDIT THAT PRODUCED THE SCALE. The defects
# that started it were turf-monster's — a docked bar at inline z-index:9999 over
# a modal backdrop at z-[120], and a DEV MODE banner with no level at all — but
# the sweep found two of this app's own, both invisible until the numbers were
# laid side by side:
#
#   1. `.hb-drawer` sat at z-index:50, the SAME number as the pinned header it
#      has to cover. A full-cover drawer and the chrome it covers, tied, with
#      stylesheet source order as the only tiebreak.
#   2. toasts were on the engine's old default of 60 — above the header, BELOW
#      the modal host at 120 — so a toast fired from an open modal was painted
#      behind it. This app never overrode the layer, so it never noticed.
#
# The scale is the engine's (engine.css `-- Layer scale`); application.css
# mirrors it until the pin reaches the gem that ships it. This test pins the
# ADOPTION: that the blocking layers read tiers, that the two defects above stay
# fixed by ORDER rather than by luck, and that the next bare number is refused
# where it is written.
class LayerScaleAdoptionTest < ActionDispatch::IntegrationTest
  CSS       = Rails.root.join("app/assets/tailwind/application.css")
  HEARTBEAT = Rails.root.join("app/assets/tailwind/heartbeat.css")
  LAYOUT    = Rails.root.join("app/views/layouts/application.html.erb")
  HOST      = Rails.root.join("app/views/studio/modals/_host.html.erb")

  # Comments are prose, and these files EXPLAIN the defect using the very numbers
  # being banned. Scanning them would make documenting the fix impossible.
  def markup_of(path)
    Pathname(path).read
                  .gsub(%r{/\*.*?\*/}m, " ")
                  .gsub(/<%#.*?%>/m, " ")
                  .gsub(/<!--.*?-->/m, " ")
  end

  # For the drift scan only: collapsing token reads keeps a fallback like
  # var(--z-drawer, 150) from reading as a bare 150.
  def code_of(path)
    markup_of(path).gsub(/var\([^)]*\)/, "var()")
  end

  # The RESOLVED GEM's engine.css, not this app's application.css.
  #
  # THIS IS THE LINE THAT CEMENTED THE SHIM. While it read application.css, the
  # adoption suite did not merely tolerate the local :root — it REQUIRED one.
  # Deleting the shim did not prompt the cleanup the shim's own comment asked
  # for, it broke the suite (2 failures + 2 KeyErrors, 'key not found:
  # --z-drawer'), so the tidy-up looked like a regression and the shim stayed.
  #
  # Reading the gem instead means these assertions verify the ENGINE's numbers.
  # If the engine re-tiers something, this app's test moves with it — which is
  # the entire point of a shared scale, and was not true before.
  ENGINE_CSS = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir)
               .join("app/assets/tailwind/studio_engine/engine.css")

  def tiers
    @tiers ||= ENGINE_CSS.read[/^:root \{(.*?)^\}/m].to_s
                         .scan(/(--z-[a-z-]+):\s*(-?\d+);/)
                         .to_h { |name, value| [ name, value.to_i ] }
  end

  test "the blocking layers read tiers, not numbers" do
    assert_includes markup_of(HOST), "z-[var(--z-modal)]",
                    "the modal host is this app's blocker and must sit on the shared tier"
    assert_includes markup_of(LAYOUT), "z-[var(--z-nav)]",
                    "the pinned header must sit on the shared tier"
    assert_includes markup_of(Rails.root.join("app/views/builders/_archive_modal.html.erb")),
                    "z-[var(--z-modal)]",
                    "the builders archive dialog is a modal and belongs on the modal tier"
  end

  # DEFECT 1, named. `.hb-drawer` and the header were both 50.
  test "a full-cover drawer outranks the header it covers" do
    heartbeat = markup_of(HEARTBEAT)

    assert_match(/\.hb-drawer\b[^}]*z-index:\s*var\(--z-drawer/m, heartbeat,
                 ".hb-drawer must read the drawer tier — it used to TIE the header at 50")
    assert_match(/\.aa-filter\b[^}]*z-index:\s*var\(--z-drawer/m, heartbeat,
                 ".aa-filter is the same shape of drawer and takes the same tier")
    assert_operator tiers.fetch("--z-drawer"), :>, tiers.fetch("--z-nav"),
                    "a drawer that cannot cover the navbar is not a drawer"
  end

  # DEFECT 2, named. Toasts were on the engine default of 60, below the modal.
  test "a toast fired from an open modal is visible" do
    # ASSERTED ON THE ENGINE, not this app. The app used to carry
    # `--studio-toast-z: var(--z-toast)` in its adoption shim; the engine's own
    # flash partial now defaults the seam to the tier
    # (`var(--studio-toast-z, var(--z-toast, 400))`), so the local override was
    # redundant and went with the shim. The PROPERTY is unchanged — the toast
    # still resolves to the shared tier — only its owner moved, which is the
    # whole point of deleting the shim.
    flash = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir)
            .join("app/views/layouts/studio/_flash.html.erb").read

    assert_match(/--studio-toast-z,\s*var\(--z-toast/, flash,
                 "the engine's toast seam must fall back to the shared tier")
    assert_operator tiers.fetch("--z-toast"), :>, tiers.fetch("--z-modal"),
                    "a toast fired from an open modal must outrank the modal backdrop"
  end

  test "nothing docked, pinned or drawered can cover a modal" do
    %w[--z-docked --z-nav --z-drawer].each do |below|
      assert_operator tiers.fetch(below), :<, tiers.fetch("--z-modal"),
                      "#{below} must stay below --z-modal — a modal is the active task"
    end
    assert_operator tiers.fetch("--z-banner"), :>, tiers.fetch("--z-modal"),
                    "the environment bars must stay reachable over a modal"
  end

  # A LEVEL ALONE IS NOT THE FIX. The first cut of the lift used `position:
  # relative`, which reads correctly at the top of a page and leaves the bars off
  # screen for anyone who scrolled — measured on a consumer at scrollY 900:
  # relative put the stack at top -900, sticky at top 0. `fixed` pins too, but
  # pulls the stack out of flow and the page jumps by its height.
  test "the modal-open lift PINS the bars and finds its hook" do
    # ALSO ENGINE-OWNED NOW. This app duplicated the engine's
    # `body.modal-open .studio-bar-stack` lift inside the adoption shim; the
    # engine ships it at engine.css and the duplicate went with the shim. Read
    # the gem so this assertion tracks the rule that actually applies — a copy
    # in this app could drift from it silently, which is the defect the shim
    # deletion exists to end.
    engine_css = Pathname(Gem.loaded_specs.fetch("studio-engine").gem_dir)
                 .join("app/assets/tailwind/studio_engine/engine.css").read
    lift = engine_css[/body\.modal-open \.studio-bar-stack.*?\}/m]

    refute_nil lift, "the engine's modal-open lift rule is gone"
    assert_match(/position:\s*sticky/, lift, "the lift must PIN the bars, not merely raise them")
  end

  # The lift only reaches the bars because they are the header's SIBLING. A bar
  # nested inside a header that carries a z-index composites at the HEADER's
  # level, clamped, whatever it asks for — that was turf-monster's actual defect.
  # bar_stack_adoption_test owns the structural assertion; this is the reason it
  # matters to the layer scale, asserted where the tiers are.
  test "the stack is not nested inside the pinned header" do
    layout = markup_of(LAYOUT)
    stack  = layout.index(%(render "studio/banners/stack"))
    header = layout.index("<header")

    refute_nil stack, "the layout must render the engine bar stack"
    assert_operator stack, :<, header,
                    "a stack inside the header is clamped to the header's level"
  end

  # THE LIFT DEPENDS ON A WORKING SCROLL LOCK, and this app's was inert.
  # Measured 2026-08-27 before the fix: with a modal open, a real wheel gesture
  # scrolled the page 600px → 1000px and the sticky header slid away with it.
  #
  # `body { overflow: hidden }` locks the VIEWPORT only while it propagates to
  # it, and it propagates only while `html` is `overflow: visible`. The engine's
  # link-sidebar sets `html { overflow-x: clip }` — right on its own terms, clip
  # makes no scroll container — but it ends the propagation, so the lock stopped
  # locking and started making BODY a scroll container pinned at scrollTop 0.
  # Every position:sticky child of body then has a scrollport that never moves.
  #
  # Hence: lock html, and put body back to visible so it is not a second scroll
  # container. Both halves are load-bearing; this test names them individually
  # so neither can be dropped as redundant.
  test "the modal scroll lock goes on the element that actually scrolls" do
    host = markup_of(HOST)

    assert_match(/html:has\(body\.modal-open\)\s*\{[^}]*overflow:\s*hidden/, host,
                 "the lock must be on html — on body it stops propagating the moment " \
                 "anything sets overflow on html, and this app's link sidebar does")
    assert_match(/body\.modal-open\s*\{[^}]*overflow:\s*visible/, host,
                 "body must go back to visible, or it stays a scroll container that " \
                 "never scrolls and every sticky child of it stops sticking")
  end

  test "nothing in this app paints at a bare blocking number" do
    files = Dir[Rails.root.join("app/views/**/*.erb")] +
            Dir[Rails.root.join("app/assets/tailwind/**/*.css")]

    offenders = files.flat_map do |path|
      code  = code_of(path)
      hits  = code.scan(/z-index:\s*(\d+)/).flatten
      hits += code.scan(/\bz-\[(\d+)\]/).flatten
      hits.map(&:to_i).select { |n| n >= 100 }
          .map { |n| "#{Pathname(path).relative_path_from(Rails.root)} → #{n}" }
    end

    assert_empty offenders,
                 "use a --z-* tier, not a bare number:\n  #{offenders.join("\n  ")}"
  end
end
