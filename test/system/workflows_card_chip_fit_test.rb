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
#
# THE CARD IS EXPANDED FIRST, and that is load-bearing. Rows past +compact_limit+ (3)
# are hidden behind the card's Show All toggle, and a display:none box measures 0x0 —
# scrollWidth 0, clientWidth 0, height 0 — which sails through every check below. So
# this file silently measured 10 of 12 chips: `full-cycle` and any THIRD act a soul
# gained were exempt, and the third act is exactly where a new one lands. A file that
# exists to catch "a longer future act" could not see the future act. Measured
# 2026-09-09. +assert_every_chip_was_measured+ is the control that keeps it honest.
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


  # THE CARVE-OUT'S REASON, HELD. tasks/_heartbeats_card states that
  # `sleeper-auction-watch` cannot be a chip because its 21-character slug clips the
  # card's chip. That is a claim about pixels, so it is asserted against pixels — and
  # it is asserted in BOTH directions, because the two acts kept off this card are
  # kept off for DIFFERENT reasons and conflating them is how the wrong one gets
  # copied forward. `archive-shipped` fits fine; it is absent because
  # production-deploy already runs it. If the card is ever widened enough for the
  # auction slug to fit, this reddens and the comment must be rewritten rather than
  # left standing as a reason that has quietly expired.
  DESIGN_WIDTH = 1536
  OFF_CARD_FITS     = "archive-shipped".freeze        # 15 chars — absent for a NON-geometry reason
  OFF_CARD_TOO_WIDE = "sleeper-auction-watch".freeze  # 21 chars — absent because it does not fit

  test "the card's chip budget still explains which acts are kept off it" do
    page.driver.browser.manage.window.resize_to(DESIGN_WIDTH, 1000)
    visit deployments_path
    assert_selector "[data-test='heartbeats-card']", wait: 10
    reveal_compact_rows

    chip = page.all("[data-test='heartbeats-card'] button[data-row='action'] code", visible: :all).first
    assert chip, "no act chip to measure the budget against"

    wide = measure_in_chip(chip, OFF_CARD_TOO_WIDE)
    assert_operator wide[:need], :>, wide[:room],
                    "#{OFF_CARD_TOO_WIDE} now needs #{wide[:need]}px of #{wide[:room]}px and FITS. " \
                    "The card's comment in tasks/_heartbeats_card keeps it off on the grounds that " \
                    "it clips; that reason has expired, so rewrite the comment rather than leave a " \
                    "dead rationale standing. The product decision is separate and still stands — " \
                    "see docs/agents/agents/turf_monster/HEARTBEAT.md."

    snug = measure_in_chip(chip, OFF_CARD_FITS)
    assert_operator snug[:need], :<=, snug[:room],
                    "#{OFF_CARD_FITS} no longer fits (#{snug[:need]}px of #{snug[:room]}px). It is " \
                    "off the card because production-deploy runs it, NOT because of width — if the " \
                    "chip has shrunk this far, the acts that ARE on the card are in trouble too."
  end

  private

  def assert_chips_fit_at(width)
    page.driver.browser.manage.window.resize_to(width, 1000)
    visit deployments_path
    assert_selector "[data-test='heartbeats-card']", wait: 10
    reveal_compact_rows

    acts = page.all("[data-test='heartbeats-card'] button[data-row='action'] code", visible: :all)
    heads = page.all("[data-test='heartbeats-card'] button[data-row='heartbeat'] code", visible: :all)
    assert_operator acts.size, :>=, 7, "expected the souls' act chips to render at #{width}px"
    assert_equal 5, heads.size, "expected five row-1 heartbeat chips at #{width}px"
    assert_every_chip_was_measured(acts, width)

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

  # Open the Show All toggle so the rows past +compact_limit+ have real boxes, then
  # wait for Alpine to paint them. Without this every third act measures 0x0.
  def reveal_compact_rows
    return unless page.has_selector?("[data-test='heartbeat-compact-toggle']", wait: 2)

    find("[data-test='heartbeat-compact-toggle']").click
    deadline = Time.now + 5
    loop do
      widths = act_chip_widths
      break if widths.any? && widths.none?(&:zero?)
      break if Time.now > deadline

      sleep 0.1
    end
  end

  def act_chip_widths
    page.all("[data-test='heartbeats-card'] button[data-row='action'] code", visible: :all)
        .map { |c| page.evaluate_script("arguments[0].scrollWidth", c).to_i }
  end

  # The control for the blind spot in the header. A hidden chip is not a passing
  # chip — it is an unmeasured one, and this file must never report a verdict on a
  # box it never saw.
  def assert_every_chip_was_measured(acts, width)
    unmeasured = acts.filter_map do |c|
      text = c.text(:all).to_s.strip
      text if page.evaluate_script("arguments[0].scrollWidth", c).to_i.zero?
    end
    assert_empty unmeasured,
                 "At #{width}px these act chips measured 0px wide, which means they were HIDDEN "                  "when this file checked them — not that they fit. Rows past compact_limit are "                  "behind the Show All toggle; reveal_compact_rows must open it before measuring."
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


  # Measure a hypothetical phrase in a REAL chip: same font, same padding, same
  # column. The text is restored before returning, so the page is left as found.
  def measure_in_chip(code, text)
    box = page.evaluate_script(<<~JS, code, text)
      (function (el, t) {
        var original = el.textContent;
        el.textContent = t;
        var out = { need: el.scrollWidth, room: el.clientWidth };
        el.textContent = original;
        return out;
      })(arguments[0], arguments[1])
    JS
    { need: box["need"].to_i, room: box["room"].to_i }
  end
end
