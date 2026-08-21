require "test_helper"

# [component] components/_overflow_fade — IS THE MASK WIRED TO THE BOX.
#
# The bug this file exists for (task: refresh-overflow-fade-on-resize): the
# partial decided its fade from ONE measurement at init and then re-took it on
# `@resize.window.debounce.150ms` and nothing else. A window resize is one CAUSE
# of the box changing; it is not the only one, and on this app it is the rarest.
# The box also moves when an async value paints into a neighbouring slot (the
# category chip beside .aa-goal, the claim chip on a task card), when a font
# swaps, when a sibling expands, and when a Turbo stream replaces the row's
# content. Every one of those arrived after the only measurement anyone took, so
# the mask stayed at whatever it was told at init — and at init the neighbouring
# slot is usually still on its narrow, un-hydrated render, which is exactly when
# the text has the most room and looks like it fits.
#
# The same class of bug in turf-monster (PR 391) was worse than reported: the
# mask never applied on the live path AT ANY WIDTH, because the single
# measurement ran before an async balance finished painting and squeezed the box.
#
# WHAT THIS TIER CAN AND CANNOT PROVE. It cannot prove the mask PAINTS — that
# needs a layout engine and a compositor, and e2e/overflow_fade.spec.js asserts
# it in decoded pixels against a mask-forced-off reference. What it CAN prove is
# that the component is wired to re-measure at all, which is worth its own tier
# because the failure is SILENT: a stale mask renders a perfectly good-looking
# box with a hard-cut edge, and nothing logs.
class OverflowFadeComponentTest < ActionView::TestCase
  LONG = "a label far too long to fit inside the box it was given".freeze

  def render_fade(**locals)
    render partial: "components/overflow_fade",
           locals: { text: LONG }.merge(locals)
  end

  # The x-data body. It contains `>` (`overflowPx > 1`) and `(` `)`, so it is
  # read as the quoted attribute value it is rather than by tag-scanning.
  def x_data
    render_fade if rendered.blank?
    value = rendered[/x-data="([^"]*)"/m, 1]
    assert value, "the fade root must carry an x-data component: #{rendered}"
    value
  end

  def style_binding
    render_fade if rendered.blank?
    value = rendered[/:style="([^"]*)"/m, 1]
    assert value, "the mask has to be bound, not hard-coded: #{rendered}"
    value
  end

  test "[component] the mask follows the BOX, through a ResizeObserver" do
    render_fade

    assert_includes x_data, "ResizeObserver",
                    "the fade must observe the EFFECT (this box changed size), not " \
                    "subscribe to one CAUSE of it. A window-resize subscription misses " \
                    "an async value painting into a neighbouring slot, a font swap, a " \
                    "sibling expanding, and a Turbo stream replacing the row — none of " \
                    "which announce themselves, and all of which move this box.\n" \
                    "x-data was: #{x_data}"
  end

  test "[component] the observer watches the box AND the text inside it" do
    render_fade

    assert_includes x_data, "observe(this.$el)",
                    "the container is what shrinks when a neighbour widens"
    assert_includes x_data, "observe(this.$refs.fadeInner)",
                    "a font swap changes the TEXT's width while the container stands " \
                    "still, so watching only the container misses it"
  end

  test "[component] the observer is released with the component" do
    render_fade

    assert_includes x_data, "destroy()",
                    "the observer belongs to the component instance. Turbo's snapshot " \
                    "cache re-inits Alpine over restored DOM, so an observer that is " \
                    "not released leaves one behind per navigation"
    assert_includes x_data, "disconnect()",
                    "destroy() must actually release the observer, not just drop the " \
                    "reference to it"
  end

  test "[component] a measurement in flight cannot outlive the component" do
    render_fade

    # The first measurement waits a tick, because x-ref children are not wired
    # when the parent's init() runs. That tick is a window in which the element
    # can be torn down, and an observer created after destroy() has already run
    # is an observer nobody will ever disconnect.
    assert_includes x_data, "dead",
                    "init() defers to $nextTick, so destroy() must be able to cancel " \
                    "the deferred setup: #{x_data}"
  end

  test "[component] the debounced window-resize subscription is gone" do
    render_fade

    refute_includes rendered, "resize.window",
                    "the observer supersedes it. Keeping both mounts a redundant " \
                    "window listener per instance, and a board renders dozens of these"
  end

  test "[component] the mask reads reactive state, so a re-measure repaints it" do
    render_fade

    assert_match(/\A!overflows \?/, style_binding,
                 "the mask must be driven by the component's reactive flag — that is " \
                 "what turns a fresh measurement into a fresh paint. It also states " \
                 "the negative control: a label that FITS gets no mask at all. " \
                 "Style was: #{style_binding}")
    assert_includes style_binding, "fadeRight"
    assert_includes style_binding, "fadeLeft"
  end

  test "[component] the root is tagged for the paint and leak probes" do
    render_fade

    assert_select "[data-overflow-fade]", count: 1,
                  message: "the pixel probe has to find this box, and the observer-leak " \
                           "probe has to count these boxes, without depending on a " \
                           "utility-class selector that styling is free to change"
  end

  test "[component] the fade still renders its text and its marquee" do
    render_fade(scroll_when: "hovered", class: "text-sm")

    assert_includes rendered, LONG
    assert_select "[data-overflow-fade] [x-ref=fadeInner]"
    assert_includes x_data, "mask-image"
    assert_includes rendered, "translateX"
  end

  test "[component] a fade with no scroll_when still measures" do
    render_fade

    assert_includes x_data, "ResizeObserver"
    # scroll_when defaults to the literal `false`, so the marquee is inert while
    # the fade still measures — the two are independent.
    assert_includes rendered, "((overflows && (false)) ? -overflowPx : 0)"
  end
end
