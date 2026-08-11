# frozen_string_literal: true

require "test_helper"

# [component] The hub renders the engine's bar STACK as its header's sibling
# (studio-engine >= 0.33) and pins the header at a STATIC top-0
# (studio-engine >= 0.39).
#
# WHAT CHANGED, and why these assertions were rewritten rather than relaxed.
# 0.33 made the stack sticky and had it MEASURE itself, publishing its height as
# --studio-bars-h for the header's `top` to read. The header therefore painted at
# the server's estimate and moved when the ResizeObserver's measurement landed —
# the jump the operator reported. 0.39.0 deleted the property: the bars sit in
# normal flow and occupy their own height, so a header sticky at top-0 starts
# below them with nothing to compute.
#
# This file used to assert the layout KEPT the `top:var(--studio-bars-h, 0px)`
# spelling. That assertion was correct on 0.33-0.38 and pins the defect on 0.39+,
# so it is REPLACED by its opposite here, not loosened away. (An adopted app that
# still carries the old spelling is not broken — it resolves to the 0px fallback —
# but this layout no longer carries it, and a reader should not hunt a variable
# that no longer exists.)
#
# The stack's own behaviour is the engine's to test, and is tested there. What
# only this repo can assert is the adoption seam: that the banner is not nested
# inside the header, that the header's offset is static, and that the page still
# has exactly one pinned header.
class BarStackAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

  # The release that deleted the measured custom property (studio-engine
  # CHANGELOG 0.39.0, "Removed: `--studio-bars-h` is gone").
  STATIC_PIN_FROM = Gem::Version.new("0.39")

  test "the layout renders the stack, not the bare environment banner" do
    layout = LAYOUT.read

    assert_includes layout, %(render "studio/banners/stack")
    assert_not_includes layout, %(render "studio/banners/environment"),
                        "the stack renders the environment bar now — a direct call would double it"
  end

  # The whole point of the change: sibling, not child.
  test "the stack is rendered before the header, not inside it" do
    layout = LAYOUT.read

    assert_operator layout.index(%(render "studio/banners/stack")), :<, layout.index("<header"),
                    "the stack must precede the header — nesting it is what this replaced"
  end

  # Replaces "the header offsets by the published height". Both halves matter:
  # the positive claim that a static pin is present, and the refutation that the
  # offset is not derived from anything published at runtime. The refutation is
  # written against `top:var(` generally, not the one retired property name —
  # reading the offset from ANY runtime-published value is the defect class, so a
  # rename would otherwise walk straight back in.
  test "the header pins statically rather than offsetting by a published height" do
    layout = LAYOUT.read

    assert_includes layout, "sticky top-0",
                    "the header pins at a static top-0 now that the bars hold their own space"
    assert_no_match(/top:\s*var\(/, layout,
                    "a var()-derived top is the jump: the header paints at one value " \
                    "and moves when the real one lands")
  end

  # Counted on the RENDERED page, not on this app's layout file. The second pinned
  # header would arrive from the ENGINE — studio-engine's layouts/_navbar emits
  # vt-pinned-header whenever pin_header is set — so scanning this file could never
  # see it, and the assertion would stay green through the exact regression it
  # names. A duplicate view-transition-name silently disables EVERY transition on
  # the page, so this is asserted rather than hoped.
  test "exactly one pinned header survives the change" do
    get root_path

    assert_equal 1, response.body.scan("vt-pinned-header").length
  end

  test "the engine supplies the stack partial this layout now depends on" do
    engine_views = Gem.loaded_specs["studio-engine"].full_gem_path

    assert File.exist?(File.join(engine_views, "app/views/studio/banners/_stack.html.erb")),
           "studio-engine >= 0.33 must ship studio/banners/_stack"
  end

  # The floor is LOAD-BEARING and is asserted as a NUMBER, not a string. The
  # render call above works from 0.33, so the partial-exists test passes on every
  # version in the range — but on 0.33-0.38 the stack is STICKY, and this
  # layout's static top-0 header would sit UNDERNEATH the bars. `~> 0.33` and
  # `~> 0.39` differ by one character and by whether the navbar is visible.
  test "the resolved engine is at or past the release that made the pin static" do
    resolved = Gem.loaded_specs["studio-engine"].version

    assert_operator resolved, :>=, STATIC_PIN_FROM,
                    "studio-engine #{resolved} still pins the bar stack sticky and publishes " \
                    "--studio-bars-h, so this layout's static top-0 header would render under the bars"
  end

  test "a rendered page carries the bars and a statically pinned header" do
    get root_path

    assert_response :success
    assert_includes response.body, "studio-bar-stack"

    header = css_select("header.vt-pinned-header").first
    assert_not_nil header

    # A CENSUS, not a substring probe: asserting only that `top-0` is present
    # would pass with a conflicting `top-4` added later in the list, and asserting
    # only its absence would pass if the pin were deleted outright. The set of
    # top-* utilities on the header is exactly one, and it is top-0.
    tops = header["class"].to_s.scan(/\btop-\S+/)
    assert_equal ["top-0"], tops,
                 "the header's vertical pin is a single static utility: #{tops.inspect}"

    assert_no_match(/top:\s*var\(/, header["style"].to_s,
                    "an inline var()-derived top would override the static pin and bring the jump back")

    # The property is UNSET on the rendered page — asserted globally rather than on
    # the header, because it was the STACK that published it (an inline <style> on
    # the server, then a ResizeObserver overwriting it). This is the absence the
    # previous cut of this file deferred with "once the pin clears 0.37.0, assert
    # the absence here"; the pin has now cleared it.
    assert_no_match(/--studio-bars-h/, response.body,
                    "nothing publishes or reads the retired property any more")

    # Paired with the positive claim above that the stack rendered: the stack now
    # reserves space by OCCUPYING it, so it ships no behaviour of its own.
    assert_empty css_select("[data-studio-bar-stack] script, [data-studio-bar-stack] style"),
                 "the stack holds its space in normal flow — it emits no script or style to measure with"

    assert_select "a[href='/_studio/local_emails']", minimum: 1
  end
end
