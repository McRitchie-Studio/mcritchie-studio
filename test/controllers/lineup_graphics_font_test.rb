# frozen_string_literal: true

require "test_helper"

# [component] The lineup graphic serves its typeface from THIS ORIGIN.
#
# WHY THIS PAGE NEEDED ITS OWN GUARD. studio-engine vendored Montserrat into
# layouts/studio/_head (0.56.4), which removed the Google Fonts dependency from
# every surface that renders that head. This layout does not render it — it is a
# standalone <head> for a capture surface — so it kept its
# `fonts.googleapis.com/css2?family=Montserrat` link after the rest of the
# ecosystem had lost one, and nothing anywhere went red about it.
#
# WHY A THIRD-PARTY FONT IS A DEFECT HERE, not an aesthetic preference. The
# stylesheet blocks the load event; the font FILES it names do not. So the page
# goes interactive in the fallback face and every glyph is re-measured when
# Montserrat lands. On the task board that race cost swallowed clicks, because a
# control moved between pointerdown and pointerup. This page is worse: script/
# capture_lineup.js drives it over CDP and records a SCREENCAST, so a late
# re-measure reflows text inside a video after the composition is judged done.
#
# ASSERTED ON THE RENDERED RESPONSE, not on the template source. A grep of the
# .erb proves what the file says; only a request proves what a browser receives —
# and asset_path is exactly the seam where a correct-looking template can still
# emit nothing usable.
class LineupGraphicsFontTest < ActionDispatch::IntegrationTest
  setup do
    @team = teams(:buffalo_bills)
  end

  test "the lineup graphic asks no third party for its font" do
    get team_lineup_graphic_path(@team.slug)
    assert_response :success

    assert_no_match(/fonts\.googleapis\.com/, response.body,
                    "the lineup graphic still pulls its stylesheet from Google Fonts — the font " \
                    "files it names do not block the load event, so the page paints in the " \
                    "fallback face and re-measures every glyph mid-capture")
    assert_no_match(/fonts\.gstatic\.com/, response.body,
                    "the lineup graphic still fetches font FILES from a third party")
  end

  test "the lineup graphic serves Montserrat from the asset pipeline" do
    get team_lineup_graphic_path(@team.slug)
    assert_response :success

    # The digested path is the proof the asset RESOLVED. A template that emits a
    # bare, undigested filename renders without raising and 404s in the browser,
    # which is the failure this assertion exists to separate from success.
    assert_match(%r{/assets/studio/montserrat-latin-[0-9a-f]{16,}\.woff2}, response.body,
                 "expected a digested, same-origin Montserrat woff2 from studio-engine's vendored " \
                 "assets; without it the @font-face names a file the browser cannot fetch and the " \
                 "page silently falls back to system-ui")

    assert_match(/@font-face/, response.body, "the layout must declare the face it just preloaded")
    assert_match(/rel="preload"[^>]*montserrat/, response.body,
                 "the face must be preloaded, or the browser discovers it only when it first needs " \
                 "to paint text — which is the delay this change exists to remove")
  end

  test "the face blocks rather than falling back on a capture surface" do
    get team_lineup_graphic_path(@team.slug)
    assert_response :success

    # DELIBERATELY DIFFERENT FROM THE ENGINE, which uses font-display: optional.
    # `optional` grants no swap period: the font either arrives inside a ~100ms
    # window or that page-load uses the fallback and never corrects. On an
    # interactive page that is the right trade. On a CAPTURE surface it is the
    # worst available failure — the recording ships branded in system-ui with
    # nothing red anywhere to say so. `block` cannot do that: it waits, then
    # paints the real face, and the wait is free here because capture_lineup.js
    # holds for networkidle and body[data-images-ready='true'] before recording a
    # single frame.
    assert_match(/font-display:\s*block/, response.body,
                 "the lineup graphic must use font-display: block. With `optional` a slow load " \
                 "silently records the whole screencast in the fallback face.")
    assert_no_match(/font-display:\s*(optional|swap)/, response.body,
                    "`optional` can silently ship the wrong typeface, and `swap` re-measures every " \
                    "glyph mid-capture — the exact reflow this change removes")
  end
end
