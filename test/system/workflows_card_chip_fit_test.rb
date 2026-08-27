require "application_system_test_case"

# [system] The Workflows card holds five soul columns inside a HALF-width dashboard
# card, which leaves each chip ~126px. Two different rules apply, and conflating them
# is what made this hard:
#
#   ACT rows  — a single hyphenated token (`production-deploy`). CSS breaks at the
#               hyphen, so ordinary wrapping renders it as two commands. These must
#               sit on ONE line and must not be ellipsised, or the phrase cannot be
#               read off the card at all.
#   ROW 1     — a phrase ("Turf Monster Heartbeat", 22 chars). It does not fit 126px
#               at any readable size, so it is ALLOWED to wrap — but only at its
#               spaces, never mid-word, and never clipped.
#
# Both are measured from the RENDERED box, not asserted as class strings: a class
# assertion stays green through a font swap, a Tailwind upgrade, or a longer act name
# — exactly the changes that would silently reintroduce the break.
class WorkflowsCardChipFitTest < ApplicationSystemTestCase
  setup do
    %w[carl avi steffon alex].each { |s| Agent.find_or_create_by!(slug: s) { |a| a.name = s.capitalize } }
    Agent.find_or_create_by!(slug: "turf-monster") { |a| a.name = "Turf Monster" }
  end

  # The card is HALF width from xl up (the dashboard goes 2-col there), so viewport
  # width alone does not predict chip width — 1300px is TIGHTER than 1100px, because
  # at 1100 the card owns the whole row and at 1300 it owns half a smaller screen.
  # Sweep either side of every step: below sm, full-width 5-up, the xl pinch, and
  # the 2xl return to 5-up.
  WIDTHS = [ 700, 1100, 1300, 1536, 1728 ].freeze

  test "every launcher chip renders its command on a single line at every width" do
    WIDTHS.each { |w| assert_chips_fit_at(w) }
  end

  private

  def assert_chips_fit_at(width)
    page.driver.browser.manage.window.resize_to(width, 1000)
    visit deployments_path
    assert_selector "[data-test='heartbeats-card']", wait: 10

    acts = page.all("[data-test='heartbeats-card'] button[data-row='action'] code", visible: :all)
    heads = page.all("[data-test='heartbeats-card'] button[data-row='heartbeat'] code", visible: :all)
    assert_operator acts.size, :>=, 7, "expected the souls' act chips to render at #{width}px"
    assert_equal 5, heads.size, "expected five row-1 heartbeat chips at #{width}px"

    broken = acts.filter_map { |c| describe_overflow(c, single_line: true) }
    assert_empty broken,
                 "At a #{width}px viewport these ACT chips wrap or are ellipsised. An act is one " \
                 "hyphenated token — split across lines it reads as two commands, and clipped it " \
                 "cannot be read off the card. Reclaim width in tasks/_heartbeats_card (column " \
                 "count, grid gap) or tasks/_heartbeat_launcher (chip padding, font)."

    clipped = heads.filter_map { |c| describe_overflow(c, single_line: false) }
    assert_empty clipped,
                 "At a #{width}px viewport these row-1 phrases are CLIPPED. Wrapping onto a second " \
                 "line at a space is fine and expected here; losing characters is not."
  end

  # Returns a description when the box misbehaves, nil when it is fine. `single_line`
  # additionally forbids wrapping; both modes forbid horizontal overflow (clipping).
  def describe_overflow(code, single_line:)
    box = page.evaluate_script(<<~JS, code)
      (function (el) {
        var cs = window.getComputedStyle(el);
        return { text: el.textContent.trim(),
                 h: el.getBoundingClientRect().height,
                 line: parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2,
                 overflow: el.scrollWidth - el.clientWidth };
      })(arguments[0])
    JS
    wrapped = box["h"] > box["line"] * 1.6
    clipped = box["overflow"] > 1
    return if !clipped && (!single_line || !wrapped)

    "#{box['text']} (height #{box['h'].round(1)}px vs line #{box['line'].round(1)}px, " \
      "overflow #{box['overflow'].round(1)}px)"
  end
end
