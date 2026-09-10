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
# this file silently measured 10 of 11 chips: `full-cycle` and any THIRD act a soul
# gained were exempt, and the third act is exactly where a new one lands. A file that
# exists to catch "a longer future act" could not see the future act. Measured
# 2026-09-09. +assert_every_chip_was_measured+ is the control that keeps it honest,
# and +reveal_compact_rows+ now fails on its OWN cause rather than falling through to
# it — a toggle that never opened is not a chip that does not fit.
#
# ELEVEN, NOT TWELVE, which is what this header said until 2026-09-09. The card renders
# 2 + 2 + 2 + 3 + 2 act chips (ApplicationHelper#heartbeat_launchers, with the card's own
# order for Carl/Avi/Steffon), and ALEX ALONE has a third act — so `full-cycle` is the
# only row past the limit today. The twelfth chip in the old count was
# `sleeper-auction-watch`, the act deliberately carved OUT of this card, which has no
# chip here to measure. A wrong number in the header of a file whose whole job is to
# stop wrong numbers standing.
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
  #
  # THE WIDTH IS 1728, NOT 1536, AND THAT IS THE MEASUREMENT'S WHOLE FOOTING. 1536 is
  # EXACTLY Tailwind's `2xl` breakpoint — the width at which the card's ladder returns to
  # `2xl:grid-cols-5`. One pixel below it the grid is `xl:grid-cols-3` and the chip hits
  # its `max-w-[11rem]` cap. MEASURED at 1535px, 2026-09-09: three columns, and
  # `sleeper-auction-watch` needs 114px of 114px — so `assert_operator 114, :>, 114`
  # fails and prints the text below, which tells the reader the carve-out's reason has
  # expired. A scrollbar, a Chrome bump, or a different runner is all it takes. An
  # argument holder that can cry "expired" for a reason unrelated to the argument
  # destroys the very property it was built to hold. 1728 is the sweep's own top width,
  # sits well inside 2xl, and measures the identical budget: the card is at its 728px cap
  # from 1536 up, so the chip's text area is the same at both. The 5-up grid is ASSERTED
  # below before anything is measured, so the test states its precondition instead of
  # assuming it.
  DESIGN_WIDTH = 1728
  OFF_CARD_FITS     = "archive-shipped".freeze        # 15 chars — absent for a NON-geometry reason
  OFF_CARD_TOO_WIDE = "sleeper-auction-watch".freeze  # 21 chars — absent because it does not fit

  test "the card's chip budget still explains which acts are kept off it" do
    page.driver.browser.manage.window.resize_to(DESIGN_WIDTH, 1000)
    visit deployments_path
    assert_selector "[data-test='heartbeats-card']", wait: 10
    reveal_compact_rows

    columns = grid_column_count
    assert_equal 5, columns,
                 "the budget asserted here is the FIVE-UP card's, and at #{DESIGN_WIDTH}px the grid " \
                 "resolved to #{columns} column(s) instead. Read nothing below until that is fixed: " \
                 "at 3-up the chip hits its max-w-[11rem] cap and both measurements are about a card " \
                 "this test did not mean to measure. Check the ladder in tasks/_heartbeats_card and " \
                 "that DESIGN_WIDTH is not sitting on a breakpoint edge."

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

  # THE GUARD FOR THE HELPER ITSELF. Everything above is only readable as a verdict about
  # WIDTH if a reveal that never happened cannot arrive dressed as one. So break the
  # reveal in each of the four ways it can fail and prove the failure names the TOGGLE —
  # and, just as load-bearing, that it does not read as the width or hidden-chip verdict.
  # Without this the fix is a promise; with it, deleting any one of the four flunks below
  # turns this red.
  test "a reveal that cannot open fails as a toggle, never as a chip width" do
    load_workflows_card

    # 1. Alpine has not hydrated the card: the compacted rows still carry x-cloak, so a
    #    click would land before @click is bound and be swallowed in silence. Its observer
    #    is stopped first BECAUSE the signal is real — a live Alpine strips a re-added
    #    x-cloak within the microtask, which is the readiness fact the reveal relies on.
    #    Measured 2026-09-09 on Alpine 3.16.1: 0 cloaked elements under the card once
    #    hydrated, 1 with the observer stopped. The throw is deliberate — if this API ever
    #    goes, this scenario must fail loudly rather than quietly stop simulating anything.
    page.execute_script(<<~JS)
      if (!window.Alpine || !window.Alpine.stopObservingMutations) {
        throw new Error('Alpine.stopObservingMutations is gone: this scenario no longer simulates an unhydrated card.');
      }
      window.Alpine.stopObservingMutations();
      document.querySelector("#{CARD} [data-test='heartbeat-copy-row']").setAttribute('x-cloak', '');
    JS
    assert_reveal_blames_the_toggle { reveal_compact_rows(wait: 0.5) }

    # 2. No toggle at all — the card stopped offering a reveal.
    load_workflows_card
    page.execute_script(%(document.querySelector("#{TOGGLE}").remove()))
    assert_reveal_blames_the_toggle { reveal_compact_rows(wait: 0.5) }

    # 3. A toggle that is present, clickable, and INERT — the swallowed click, reproduced.
    #    The replacement carries no Alpine attributes, so Alpine has nothing to re-bind
    #    when its observer sees the new node, and the state can never flip.
    load_workflows_card
    page.execute_script(<<~JS)
      var live = document.querySelector("#{TOGGLE}");
      var dead = document.createElement('button');
      dead.setAttribute('type', 'button');
      dead.setAttribute('data-test', 'heartbeat-compact-toggle');
      dead.setAttribute('aria-expanded', 'false');
      dead.textContent = 'Show All';
      live.parentNode.replaceChild(dead, live);
    JS
    assert_reveal_blames_the_toggle { reveal_compact_rows(wait: 0.5) }

    # 4. The toggle opens and the rows never paint. Measuring is stubbed to the 0px the
    #    caller would otherwise receive and report as HIDDEN chips.
    load_workflows_card
    define_singleton_method(:act_chip_widths) { [ 0, 0 ] }
    assert_reveal_blames_the_toggle { reveal_compact_rows(wait: 0.5) }
  end

  # THE CERTIFIED-FRAME GUARD. click_when_settled promises the control had stopped moving
  # when it was clicked. A box is only a claim about the scroll position it was sampled
  # at, so that promise means something only if the box it CERTIFIED is the box the click
  # actually landed in — and the driver scrolls as the first step of the click. This asserts
  # exactly that equality, which is a fact about coordinates and not about how fast the
  # runner is: it reddens identically on a warm laptop and a starved CI box.
  #
  # IT BITES BY CONSTRUCTION: delete the scrollIntoView from click_when_settled and the
  # certified box is the pre-scroll one (measured y 894) while the click lands at the
  # post-collapse one (measured y 390), so this goes red naming both.
  test "the click lands in the very frame click_when_settled certified as settled" do
    # 700x1000 is the sweep's own narrowest width and it puts the toggle below the fold,
    # which is what forces the driver to scroll. Asserted, not assumed, below.
    page.driver.browser.manage.window.resize_to(700, 1000)
    load_workflows_card

    below_fold = toggle_gap_below_fold
    assert_operator below_fold, :>, 0,
                    "the toggle was already fully in view (#{below_fold}px past the fold), so the " \
                    "driver never had to scroll and this test exercised nothing. Widen the window or " \
                    "shorten it until the Workflows card sits below the fold again."

    record_pointerdown_box
    click_when_settled(TOGGLE)

    assert_equal last_settled_box, pointerdown_box,
                 "click_when_settled certified the toggle settled at #{last_settled_box} but the " \
                 "click was dispatched at #{pointerdown_box}. The box was measured in a coordinate " \
                 "frame the click then left: `element.click` scrolls the control into view, and that " \
                 "scroll collapses this app's sticky nav, sliding everything below it up ~32px. " \
                 "Certify the geometry AFTER entering the frame the click happens in — a longer wait " \
                 "before the scroll cannot help, because the box really is stable where it was measured."
  end

  # THE WITNESS GUARD. The settle loop clears on two identical consecutive samples, so a
  # runner starved past its 50ms sample interval cannot tell a page that HAS settled from
  # one that has not moved YET — which is how every previous fix here stayed marginal. So
  # a swallowed click must be a fact the helper reads, not a risk it estimates.
  #
  # The swallow is made DETERMINISTIC rather than waited for: a one-shot pointerdown
  # handler shoves the toggle 240px down the page, so pointerup lands somewhere else and
  # the browser fires `click` on the common ancestor — the exact production sequence, on a
  # handler instead of a runner. The retry then finds a page that is genuinely still.
  #
  # IT BITES BY CONSTRUCTION: drop the witness/retry loop from click_when_settled and this
  # goes red as "the Show All toggle did not open within 10s of the click", which is the CI
  # failure verbatim.
  test "a click swallowed under the pointer is retried, not reported as a dead toggle" do
    load_workflows_card
    swallow_the_next_click

    reveal_compact_rows

    assert_selector "#{TOGGLE}[aria-expanded='true']", wait: REVEAL_WAIT
    assert_equal 1, swallowed_clicks,
                 "the fixture never swallowed a click, so the retry was never asked for and this " \
                 "test is a green that proves nothing. Check that the pointerdown handler still " \
                 "moves the toggle further than its own height."
  end

  # A retry certifies a NEW box, so the frame guard's two sides must come from the attempt
  # that LANDED. A forced swallow runs that path everywhere, not only on a starved runner.
  test "the certified frame matches the click that landed, even after a retry" do
    page.driver.browser.manage.window.resize_to(700, 1000)
    load_workflows_card
    record_pointerdown_box
    swallow_the_next_click

    click_when_settled(TOGGLE)

    assert_equal 1, swallowed_clicks, "no retry was forced, so this proves nothing"
    assert_equal last_settled_box, pointerdown_box,
                 "retry certified #{last_settled_box} but pointerdown read #{pointerdown_box}: " \
                 "record_pointerdown_box must keep the LAST pointerdown, not an abandoned attempt's"
  end

  private

  # How far the toggle's bottom edge sits BELOW the viewport, in px. Positive means the
  # driver must scroll to reach it, which is the precondition the frame guard needs.
  def toggle_gap_below_fold
    page.evaluate_script(<<~JS).to_i
      (function () {
        var t = document.querySelector("#{TOGGLE}");
        return t ? Math.round(t.getBoundingClientRect().bottom - window.innerHeight) : 0;
      })()
    JS
  end

  # Record the toggle's box at the instant pointerdown is dispatched — the coordinate
  # frame the click really happens in. Capture phase, so nothing downstream can stop it.
  # Overwritten on EVERY pointerdown: last_settled_box is re-certified per attempt, so a
  # first-only latch would pair a retry's certified box with an abandoned attempt's.
  def record_pointerdown_box
    page.execute_script(<<~JS)
      window.__pointerdownBox = null;
      document.addEventListener('pointerdown', function () {
        var t = document.querySelector("#{TOGGLE}");
        if (!t) return;
        var r = t.getBoundingClientRect();
        window.__pointerdownBox = #{ApplicationSystemTestCase::BOX_JS};
      }, true);
    JS
  end

  def pointerdown_box
    page.evaluate_script("window.__pointerdownBox")
  end

  # Move the toggle out from under the pointer, once, on the first pointerdown. 240px is
  # far more than the button's 13px height, so pointerup cannot land on it and `click` is
  # dispatched at the common ancestor instead — the swallow, reproduced on a handler.
  # The shove is left in place: the retry must succeed against a page that has genuinely
  # stopped moving, not against one that conveniently snapped back.
  def swallow_the_next_click
    page.execute_script(<<~JS)
      window.__swallowed = 0;
      var shove = function () {
        var t = document.querySelector("#{TOGGLE}");
        if (!t) return;
        document.removeEventListener('pointerdown', shove, true);
        window.__swallowed += 1;
        t.parentElement.style.marginTop = '240px';
        t.getBoundingClientRect();
      };
      document.addEventListener('pointerdown', shove, true);
    JS
  end

  def swallowed_clicks
    page.evaluate_script("window.__swallowed").to_i
  end

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

  CARD = "[data-test='heartbeats-card']".freeze
  TOGGLE = "[data-test='heartbeat-compact-toggle']".freeze

  # The ceiling on each step of the reveal — the card's OWN first-paint budget (the
  # `wait: 10` on every assert_selector above), not a fresh number tuned on a warm
  # laptop. It bounds a hang; it is not what makes the reveal deterministic.
  REVEAL_WAIT = 10

  # Open the Show All toggle so the rows past +compact_limit+ have real boxes, then wait
  # for Alpine to paint them. Without this every third act measures 0x0.
  #
  # EVERY EXIT HERE IS A FAILURE THAT NAMES ITSELF, and that is the point of the method.
  # It used to hold two SOFT exits — `return unless has_selector?(..., wait: 2)` and
  # `break if Time.now > deadline` — and both fell through to the width assertions with
  # the chips still hidden. A hidden chip measures 0x0, so a toggle that never opened was
  # REPORTED as a chip that does not fit, and the reader was sent to tasks/_heartbeats_card
  # to reclaim pixels that were never the problem. Measured 2026-09-09: the `system` job
  # red at 1m33s naming `full-cycle` at 0px seven seconds after Puma booted, then GREEN on
  # a re-run of the same SHA. A toggle timeout and a width regression must never share a
  # message.
  #
  # READINESS SIGNALS, NOT A BIGGER NUMBER, and here is why the number could not work.
  # The race is not that the page is slow — it is that the click is UNORDERED against two
  # things that finish on their own schedule, so any fixed wait only moves the threshold:
  #
  #   ALPINE — the button is server-rendered and clickable long before `@click` is bound.
  #            A click that lands first does nothing at all: no error, no state change.
  #            Alpine strips `x-cloak` from every element it initializes, so the card
  #            SHEDDING its cloak is the hydration signal, and the click waits behind it.
  #   FONTS  — page text is Montserrat, fetched from fonts.googleapis.com; the files land
  #            AFTER `visit` returns and every glyph is re-measured, which reflows this
  #            grid under the pointer. +click_when_settled+ (application_system_test_case)
  #            exists for exactly that: pointerdown and pointerup hit different elements
  #            and the browser fires `click` on their common ancestor.
  #   THE SCROLL — and this, not the font, is what actually reddened this file. The
  #            toggle sits BELOW THE FOLD, so `element.click` scrolls to reach it, and on
  #            this app a scroll collapses the sticky nav: measured 2026-09-09 at 700x1000,
  #            the header goes 134px -> 102px over ~160ms and drags this 13px-tall button
  #            up 32px, starting a frame AFTER the scroll with `document.getAnimations()`
  #            still empty. Certifying the box BEFORE that scroll certifies a coordinate
  #            frame the click is about to leave, which is why the previous fix here
  #            stayed marginal: three runs of one unchanged SHA passed at 24.5s of suite
  #            time and failed at 30.5s and 40.5s. The fix is in click_when_settled, and
  #            the two tests below hold it.
  #
  # +wait+ is a per-step ceiling, exposed so the guard test above can drive each exit
  # without paying it four times over.
  def reveal_compact_rows(wait: REVEAL_WAIT)
    unless page.has_selector?(TOGGLE, wait: wait)
      flunk "the Workflows card rendered no Show All toggle within #{wait}s, so the rows past " \
            "compact_limit were never revealed. The card renders one whenever a soul has more rows " \
            "than compact_limit (Alex has three acts), so either the page never finished loading or " \
            "the card no longer hides rows — in which case this helper is obsolete and every chip is " \
            "already measurable. THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    unless page.has_no_selector?("#{CARD} [x-cloak]", visible: :all, wait: wait)
      flunk "Alpine had not hydrated the Workflows card within #{wait}s — its compacted rows still " \
            "carry the x-cloak that Alpine strips as it initializes each element. Clicking the Show " \
            "All toggle now would be swallowed (@click is not bound yet) and every row past " \
            "compact_limit would stay hidden at 0px. THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    click_when_settled(TOGGLE)

    unless page.has_selector?("#{TOGGLE}[aria-expanded='true']", wait: wait)
      flunk "the Show All toggle did not open within #{wait}s of the click — it still reports " \
            "aria-expanded=#{toggle_expanded_state.inspect} (nil means Alpine never bound the " \
            "attribute at all). The click was swallowed, or the toggle no longer drives " \
            "heartbeatsExpanded. THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      widths = act_chip_widths
      return if widths.any? && widths.none?(&:zero?)

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "the Show All toggle reported OPEN but #{widths.count(&:zero?)} of #{widths.size} act " \
              "chips still measured 0px #{wait}s later, so the revealed rows never painted. " \
              "THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
      end

      sleep 0.1
    end
  end

  # Load /deployments and hold until the Workflows card is both rendered AND hydrated —
  # the state every scenario in the guard test starts from, so each one breaks exactly
  # the thing it means to break.
  def load_workflows_card
    visit deployments_path
    assert_selector CARD, wait: REVEAL_WAIT
    assert_no_selector "#{CARD} [x-cloak]", visible: :all, wait: REVEAL_WAIT
  end

  # A reveal failure has to be readable as a TOGGLE failure by whoever finds it in a CI
  # log, which is two claims, not one: it names the toggle, and it cannot be mistaken for
  # the width verdict this file exists to deliver.
  def assert_reveal_blames_the_toggle(&block)
    error = assert_raises(Minitest::Assertion, &block)

    assert_match(/toggle/i, error.message,
                 "a reveal that failed must name the toggle. Got: #{error.message}")
    assert_match(/NOT A VERDICT ABOUT CHIP WIDTH/, error.message,
                 "a reveal that failed must disclaim the width verdict. Got: #{error.message}")
    refute_match(/wrap or are ellipsised|measured 0px wide, which means/, error.message,
                 "a reveal that failed must not arrive wearing the width or hidden-chip verdict's " \
                 "words — that confusion is the whole defect this file was fixed for.")
    error
  end

  # What the toggle currently claims about itself. nil when Alpine never bound the
  # attribute, which separates "never hydrated" from "click swallowed" in the flunk above.
  def toggle_expanded_state
    page.evaluate_script(<<~JS)
      (function () {
        var t = document.querySelector("#{TOGGLE}");
        return t ? t.getAttribute('aria-expanded') : null;
      })()
    JS
  end

  # The grid's RESOLVED track count, read off the launcher's own parent so it does not
  # depend on the card's class strings — the same reason every other measurement here
  # comes from the rendered box.
  def grid_column_count
    page.evaluate_script(<<~JS).to_i
      (function () {
        var first = document.querySelector("#{CARD} [data-test='heartbeat-launcher']");
        if (!first) return 0;
        return window.getComputedStyle(first.parentElement)
                     .gridTemplateColumns.split(' ').filter(Boolean).length;
      })()
    JS
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
                 "At #{width}px these act chips measured 0px wide, which means they were HIDDEN " \
                 "when this file checked them — not that they fit. This is NOT the toggle timing " \
                 "out: reveal_compact_rows now flunks on its own cause if the Show All toggle is " \
                 "missing, unhydrated, swallowed the click, or never painted, so by the time this " \
                 "fires the rows past compact_limit were genuinely revealed and something else is " \
                 "hiding these."
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
