require "application_system_test_case"

# [system] The Workflows chips are drawn in TWO places since the /deployments summary
# row (2026-09-18), and both are measured here from the RENDERED box:
#
#   THE CAROUSEL  the Workflows summary card — one quarter of the row at xl — shows one
#                 soul at a time, its acts TWO TO A LINE. Every slide stays laid out
#                 (the wheel slides them, it never display:nones them), so every chip is
#                 measurable without turning the wheel.
#   THE SIDEBAR   every soul and every command, one chip beside each description —
#                 display:none until the card is clicked, so it is OPENED first.
#
# Two different rules apply to a chip, and conflating them is what made this hard:
#
#   ACT rows  — a single hyphenated token (`production-deploy`). CSS breaks at the
#               hyphen, so ordinary wrapping renders it as two commands. These must
#               sit on ONE line and must not be ellipsised, or the phrase cannot be
#               read off the card at all.
#   ROW 1     — a phrase ("Turf Monster Heartbeat", 22 chars). It is ALLOWED to wrap —
#               but only at its spaces, never mid-word, and never clipped.
#
# Measured, not asserted as class strings: a class assertion stays green through a
# font swap, a Tailwind upgrade, or a longer act name — exactly the changes that would
# silently reintroduce the break.
#
# THE SIDEBAR IS OPENED BEFORE IT IS MEASURED, and that is load-bearing. A display:none
# box measures 0x0 — scrollWidth 0, clientWidth 0, height 0 — which sails through every
# check below. +assert_every_chip_was_measured+ is the control that keeps it honest, and
# +open_workflows_sidebar+ fails on its OWN cause rather than falling through to it — an
# opener that never opened is not a chip that does not fit.
#
# THIS FILE ALSO GUARDS click_when_settled's CERTIFIED-FRAME HALF (see the helper in
# application_system_test_case.rb, which names it). The opener — the Workflows summary
# card — is the control those guards click: below the fold on a short window, so the
# driver has to scroll, and a scroll collapses this app's sticky nav under the pointer.
class WorkflowsCardChipFitTest < ApplicationSystemTestCase
  setup do
    %w[carl avi steffon alex].each { |s| Agent.find_or_create_by!(slug: s) { |a| a.name = s.capitalize } }
    Agent.find_or_create_by!(slug: "turf-monster") { |a| a.name = "Turf Monster" }
  end

  # PUT THE WINDOW BACK. This is the one file that resizes, and Capybara's reset does not
  # undo it. At 700px the deploy board hides a designed-stage card, so a narrow window
  # left here failed BoardAppFilterSystemTest at its FIRST assertion, before it clicked
  # anything — measured 2026-09-10, seed 52094, and green in isolation. Runs after the
  # failure screenshot (before_teardown), so a red test is still captured at its own size.
  teardown do
    page.driver.browser.manage.window.resize_to(*ApplicationSystemTestCase::SCREEN_SIZE)
  end

  # Either side of every step the summary row takes: one card per line below sm, two
  # up from sm, four up from xl (1280 — the NARROWEST the carousel ever gets, a quarter
  # of a small screen), and the 2xl container cap.
  WIDTHS = [ 700, 1100, 1300, 1536, 1728 ].freeze

  test "every workflow chip renders its command on a single line at every width" do
    WIDTHS.each { |w| assert_chips_fit_at(w) }
  end

  # THE CARVE-OUT'S REASON, HELD. tasks/_heartbeats_card states that
  # `sleeper-auction-watch` cannot be a chip because its 21-character slug clips the
  # carousel's act chip at its narrowest. That is a claim about pixels, so it is asserted
  # against pixels — and in BOTH directions, because the two acts kept off the card are
  # kept off for DIFFERENT reasons and conflating them is how the wrong one gets copied
  # forward. `archive-shipped` fits fine; it is absent because production-deploy already
  # runs it. If the carousel is ever widened enough for the auction slug to fit, this
  # reddens and the comment must be rewritten rather than left standing as a reason that
  # has quietly expired.
  #
  # 1300, NOT 1280. 1280 is EXACTLY Tailwind's `xl` — the width at which the row goes
  # four up — and one pixel of scrollbar below it the row is two up and every chip is
  # twice as wide. A measurement that can flip on a runner's scrollbar destroys the very
  # property it was built to hold. 1300 sits inside xl, and the four-up row is ASSERTED
  # below before anything is measured, so the test states its precondition instead of
  # assuming it.
  DESIGN_WIDTH = 1300
  OFF_CARD_FITS     = "archive-shipped".freeze        # 15 chars — absent for a NON-geometry reason
  OFF_CARD_TOO_WIDE = "sleeper-auction-watch".freeze  # 21 chars — absent because it does not fit

  test "the carousel's chip budget still explains which acts are kept off it" do
    page.driver.browser.manage.window.resize_to(DESIGN_WIDTH, 1000)
    visit deployments_path
    assert_selector SUMMARY, wait: 10

    columns = summary_row_column_count
    assert_equal 4, columns,
                 "the budget asserted here is the FOUR-UP row's, and at #{DESIGN_WIDTH}px the summary " \
                 "row resolved to #{columns} column(s) instead. Read nothing below until that is " \
                 "fixed: at two up every chip is twice as wide and both measurements are about a card " \
                 "this test did not mean to measure."

    chip = page.all("#{SUMMARY} button[data-row='action'] code", visible: :all).first
    assert chip, "no act chip to measure the budget against"

    wide = measure_in_chip(chip, OFF_CARD_TOO_WIDE)
    assert_operator wide[:need], :>, wide[:room],
                    "#{OFF_CARD_TOO_WIDE} now needs #{wide[:need]}px of #{wide[:room]}px and FITS. " \
                    "The comment in tasks/_heartbeats_card keeps it off on the grounds that it " \
                    "clips; that reason has expired, so rewrite the comment rather than leave a " \
                    "dead rationale standing. The product decision is separate and still stands — " \
                    "see docs/agents/agents/turf_monster/HEARTBEAT.md."

    snug = measure_in_chip(chip, OFF_CARD_FITS)
    assert_operator snug[:need], :<=, snug[:room],
                    "#{OFF_CARD_FITS} no longer fits (#{snug[:need]}px of #{snug[:room]}px). It is " \
                    "off the card because production-deploy runs it, NOT because of width — if the " \
                    "chip has shrunk this far, the acts that ARE on the card are in trouble too."
  end

  # THE GUARD FOR THE HELPER ITSELF. Everything above is only readable as a verdict about
  # WIDTH if an opening that never happened cannot arrive dressed as one. So break the
  # opening in each of the four ways it can fail and prove the failure names the OPENER —
  # and, just as load-bearing, that it does not read as the width or hidden-chip verdict.
  test "a sidebar that cannot open fails as the opener, never as a chip width" do
    load_workflows_card

    # 1. Alpine has not hydrated the sidebar: it still carries the x-cloak Alpine strips
    #    as it initializes, so a click would land before @click is bound and be swallowed
    #    in silence. The observer is stopped first BECAUSE the signal is real — a live
    #    Alpine strips a re-added x-cloak within the microtask. The throw is deliberate —
    #    if this API ever goes, this scenario must fail loudly rather than quietly stop
    #    simulating anything.
    page.execute_script(<<~JS)
      if (!window.Alpine || !window.Alpine.stopObservingMutations) {
        throw new Error('Alpine.stopObservingMutations is gone: this scenario no longer simulates an unhydrated sidebar.');
      }
      window.Alpine.stopObservingMutations();
      document.querySelector("#{SIDEBAR}").setAttribute('x-cloak', '');
    JS
    assert_opening_blames_the_opener { open_workflows_sidebar(wait: 0.5) }

    # 2. No opener at all — the card stopped offering one.
    load_workflows_card
    page.execute_script(%(document.querySelector("#{OPENER}").remove()))
    assert_opening_blames_the_opener { open_workflows_sidebar(wait: 0.5) }

    # 3. An opener that is present, clickable, and INERT — the swallowed click,
    #    reproduced. The card is swapped for a copy stripped of every Alpine attribute,
    #    so Alpine has nothing to bind when its observer sees the new node and `panel`
    #    can never flip. Its heading button keeps the server's aria-expanded="false", so
    #    the failure it produces is the click's, not the hydration check's.
    load_workflows_card
    page.execute_script(<<~JS)
      var live = document.querySelector("#{SUMMARY}");
      var dead = live.cloneNode(true);
      [dead].concat(Array.from(dead.querySelectorAll('*'))).forEach(function (el) {
        Array.from(el.attributes).forEach(function (a) {
          if (/^(x-|@|:)/.test(a.name)) el.removeAttribute(a.name);
        });
      });
      live.parentNode.replaceChild(dead, live);
    JS
    assert_opening_blames_the_opener { open_workflows_sidebar(wait: 0.5) }

    # 4. The sidebar opens and its chips never paint. Measuring is stubbed to the 0px the
    #    caller would otherwise receive and report as HIDDEN chips.
    load_workflows_card
    define_singleton_method(:act_chip_widths) { [ 0, 0 ] }
    assert_opening_blames_the_opener { open_workflows_sidebar(wait: 0.5) }
  end

  # THE CERTIFIED-FRAME GUARD. click_when_settled promises the control had stopped moving
  # when it was clicked. A box is only a claim about the scroll position it was sampled
  # at, so that promise means something only if the geometry was certified in the SAME
  # frame the click happens in — and the driver scrolls as the first step of the click.
  #
  # IT ACCEPTS THE SCROLL POSITION OR THE BOX, NOT BOTH. On a runner whose frames arrive
  # late the settle loop can certify before the nav collapse's first rAF step, and the
  # collapse then lands between certification and pointerdown — moving the control a few
  # px, or (under scroll anchoring) scrolling the page instead. The click lands either
  # way. See assert_click_in_certified_frame for both measurements.
  #
  # IT BITES BY CONSTRUCTION: delete the scrollIntoView from click_when_settled and the
  # geometry is certified at scrollY 0 while the driver's own scroll puts the click
  # further down. The below-the-fold precondition is what guarantees the driver has to
  # scroll at all.
  test "the click lands in the very frame click_when_settled certified as settled" do
    assert_click_lands_in_the_certified_frame
  end

  # THE SAME GUARD ON A STARVED RUNNER, made deterministic with the sibling file's own
  # technique (board_filter_click_stability_test.rb stubs requestAnimationFrame): every
  # frame callback is held back 55ms, which is what a loaded headless Chrome does to the
  # nav collapse. It still reddens when the pre-scroll is deleted, because a rAF delay
  # cannot move the driver's scroll.
  test "the certified frame holds on a runner whose frames arrive late" do
    assert_click_lands_in_the_certified_frame(frame_delay_ms: 55)
  end

  # THE WITNESS GUARD. The settle loop clears on two identical consecutive samples, so a
  # runner starved past its 50ms sample interval cannot tell a page that HAS settled from
  # one that has not moved YET. So a swallowed click must be a fact the helper reads, not
  # a risk it estimates.
  #
  # The swallow is made DETERMINISTIC rather than waited for: a one-shot pointerdown
  # handler shoves the card 240px down the page, so pointerup lands somewhere else and
  # the browser fires `click` on the common ancestor — the exact production sequence, on
  # a handler instead of a runner. The retry then finds a page that is genuinely still.
  #
  # IT BITES BY CONSTRUCTION: drop the witness/retry loop from click_when_settled and this
  # goes red as "the Workflows sidebar did not open".
  test "a click swallowed under the pointer is retried, not reported as a dead opener" do
    load_workflows_card
    swallow_the_next_click

    open_workflows_sidebar

    assert_selector OPENED, wait: OPEN_WAIT
    assert_operator opener_pointerdowns, :>=, 2,
                    "only #{opener_pointerdowns} click was dispatched at the opener, so no retry ran " \
                    "and this test is a green that proves nothing: the first click landed despite the " \
                    "shove. Check that the pointerdown handler still moves the card further than its " \
                    "own height."
  end

  # A retry re-scrolls and certifies a NEW frame, so the frame guard's two sides must come
  # from the attempt that LANDED. A forced swallow runs that path everywhere, not only on a
  # starved runner. The shove moves the card 240px down, so the retry's scroll position
  # differs from the abandoned attempt's and a first-only latch cannot pass by accident.
  test "the certified frame matches the click that landed, even after a retry" do
    page.driver.browser.manage.window.resize_to(*SHORT_WINDOW)
    load_workflows_card
    record_pointerdown_frame
    swallow_the_next_click

    click_when_settled(OPENER)

    assert_operator opener_pointerdowns, :>=, 2, "no retry ran, so this proves nothing"
    landed = pointerdown_frame
    # The shove moved the card 240px, so an abandoned attempt's frame differs from the
    # landed one in BOTH readings — a first-only latch cannot pass either way.
    assert_click_in_certified_frame(landed)
  end

  private

  SUMMARY = "#agents-summary-card".freeze
  # The card's own header row: its centre is the empty gap between the title and the
  # carousel dots, so a click there lands on the CARD's surface — which is what opens the
  # sidebar — rather than on a chip or a dot, which own their clicks.
  OPENER  = "#agents-summary-card [data-test='summary-card-header']".freeze
  OPENED  = "#agents-summary-card button[data-test='summary-card-toggle'][aria-expanded='true']".freeze
  SIDEBAR = "#deploy-sidebar-agents".freeze
  CARD    = "#deploy-sidebar-agents [data-test='heartbeats-card']".freeze
  # Narrow AND short: two cards to a line pushes the Workflows card onto the summary
  # row's second line, and 560px of height puts that line below the fold, so the driver
  # has to scroll to reach it. Asserted, not assumed, in the certified-frame body.
  SHORT_WINDOW = [ 700, 560 ].freeze

  # The ceiling on each step of the opening — the card's OWN first-paint budget (the
  # `wait: 10` on every assert_selector above), not a fresh number tuned on a warm
  # laptop. It bounds a hang; it is not what makes the opening deterministic.
  OPEN_WAIT = 10

  # How far the opener's bottom edge sits BELOW the viewport, in px. Positive means the
  # driver must scroll to reach it, which is the precondition the frame guard needs.
  def opener_gap_below_fold
    page.evaluate_script(<<~JS).to_i
      (function () {
        var t = document.querySelector("#{OPENER}");
        return t ? Math.round(t.getBoundingClientRect().bottom - window.innerHeight) : 0;
      })()
    JS
  end

  # The body of both certified-frame tests. +frame_delay_ms+ holds every
  # requestAnimationFrame callback back that long, installed AFTER the card has hydrated
  # so it starves the nav collapse, not Alpine's own start-up.
  def assert_click_lands_in_the_certified_frame(frame_delay_ms: nil)
    page.driver.browser.manage.window.resize_to(*SHORT_WINDOW)
    load_workflows_card

    below_fold = opener_gap_below_fold
    assert_operator below_fold, :>, 0,
                    "the opener was already fully in view (#{below_fold}px past the fold), so the " \
                    "driver never had to scroll and this test exercised nothing. Shorten SHORT_WINDOW " \
                    "until the Workflows card sits below the fold again."

    delay_animation_frames(frame_delay_ms) if frame_delay_ms

    record_pointerdown_frame
    click_when_settled(OPENER)

    landed = pointerdown_frame
    assert landed, "no pointerdown reached the opener, so there is no click frame to compare"
    assert_click_in_certified_frame(landed)
    assert_selector OPENED, wait: OPEN_WAIT
  end

  # THE CLICK LANDED WHERE IT WAS CERTIFIED — proved by ANY of three readings, because a
  # late nav collapse after certification shows up as one, the other, or a little of each:
  #
  #   same scroll position  the collapse slid the control a few px, but the page did not
  #                         scroll (measured 2026-09-10 on the old Workflows toggle:
  #                         certified 328,422, clicked at 328,418, same scrollY)
  #   same box              Chrome's SCROLL ANCHORING absorbed the collapse by scrolling
  #                         the page instead, so the control never moved on screen
  #                         (measured 2026-09-18 on this opener with frames delayed 55ms:
  #                         box 33,201,292,17 at both, scrollY 408 then 376 — exactly the
  #                         collapse's 32px)
  #   centre still on it    BOTH at once — anchoring scrolled 32px AND the box slid 4px
  #                         (measured 2026-09-19, 2 of 11 runs: scrollY 408 then 376, box
  #                         y 197 then 201), so the certified centre is still on the control
  #
  # Which one a layout gets depends on where Chrome picks its anchor node, which is why
  # a guard pinned to only one of them went red the moment the control moved. The bug this
  # guards against moves BOTH: delete the pre-scroll and certification happens at the
  # load's scroll position while the driver's own scroll moves the page AND the control.
  def assert_click_in_certified_frame(landed)
    same_scroll = last_settled_scroll_y == landed["scroll_y"]
    same_box = last_settled_box == landed["box"]
    assert same_scroll || same_box || certified_centre_on?(landed["box"]),
           "click_when_settled certified the opener at scrollY #{last_settled_scroll_y} " \
           "(box #{last_settled_box}) but the click was dispatched at scrollY " \
           "#{landed['scroll_y']} (box #{landed['box']}) — BOTH moved, off the certified centre. " \
           "The geometry was certified in a frame the click then left: `element.click` scrolls " \
           "the control into view, and " \
           "that scroll collapses this app's sticky nav under the pointer. Certify AFTER " \
           "entering the frame the click happens in — a longer wait before the scroll cannot " \
           "help, because the box really is stable where it was measured."
  end

  # Is the centre of the box the settle loop certified inside the box the click landed in?
  def certified_centre_on?(landed_box)
    x, y, w, h = last_settled_box.to_s.split(",").map(&:to_f)
    lx, ly, lw, lh = landed_box.to_s.split(",").map(&:to_f)
    (x + w / 2).between?(lx, lx + lw) && (y + h / 2).between?(ly, ly + lh)
  end

  # Hold every requestAnimationFrame callback back +ms+, and prove the stub is live before
  # anything relies on it: a stub that silently failed to install would turn the slow-frame
  # test into a second copy of the fast one, green for no reason.
  def delay_animation_frames(ms)
    page.execute_script(<<~JS, ms)
      var delay = arguments[0];
      var real = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = function (cb) {
        return setTimeout(function () { real(cb); }, delay);
      };
    JS
    lag = page.evaluate_async_script(<<~JS)
      var done = arguments[arguments.length - 1];
      var t0 = performance.now();
      window.requestAnimationFrame(function () { done(Math.round(performance.now() - t0)); });
    JS
    assert_operator lag.to_i, :>=, ms,
                    "requestAnimationFrame answered in #{lag}ms with a #{ms}ms delay installed, so " \
                    "the stub is not live and this is not a slow-frame run"
  end

  # Record the frame the click really happens in — the scroll position, plus the opener's
  # box for the failure message — at the instant pointerdown is dispatched. Capture phase,
  # so nothing downstream can stop it. Overwritten on EVERY pointerdown: the settle loop
  # re-certifies per attempt, so a first-only latch would pair a retry's certified frame
  # with an abandoned attempt's.
  def record_pointerdown_frame
    page.execute_script(<<~JS)
      window.__pointerdownFrame = null;
      document.addEventListener('pointerdown', function () {
        var t = document.querySelector("#{OPENER}");
        if (!t) return;
        var r = t.getBoundingClientRect();
        window.__pointerdownFrame = { box: #{ApplicationSystemTestCase::BOX_JS},
                                      scroll_y: Math.round(window.scrollY) };
      }, true);
    JS
  end

  def pointerdown_frame
    page.evaluate_script("window.__pointerdownFrame")
  end

  # Move the opener out from under the pointer, once, on the first pointerdown. 240px is
  # far more than the header's own height, so pointerup cannot land on it and `click` is
  # dispatched at the common ancestor instead — the swallow, reproduced on a handler.
  # The shove moves the whole CARD (the header's parent), so the stray click cannot land
  # on the card's surface either. It is left in place: the retry must succeed against a
  # page that has genuinely stopped moving, not one that conveniently snapped back.
  #
  # Every pointerdown dispatched AT the opener is counted, because that — not the shove —
  # is what proves a retry ran.
  def swallow_the_next_click
    page.execute_script(<<~JS)
      window.__openerPointerdowns = 0;
      document.addEventListener('pointerdown', function (e) {
        var t = document.querySelector("#{OPENER}");
        if (t && t.contains(e.target)) { window.__openerPointerdowns += 1; }
      }, true);
      var shove = function () {
        var t = document.querySelector("#{OPENER}");
        if (!t) return;
        document.removeEventListener('pointerdown', shove, true);
        t.parentElement.style.marginTop = '240px';
        t.getBoundingClientRect();
      };
      document.addEventListener('pointerdown', shove, true);
    JS
  end

  def opener_pointerdowns
    page.evaluate_script("window.__openerPointerdowns").to_i
  end

  def assert_chips_fit_at(width)
    page.driver.browser.manage.window.resize_to(width, 1000)
    visit deployments_path
    assert_selector SUMMARY, wait: 10

    # THE CAROUSEL: every slide is laid out, so every chip has a real box already.
    carousel_acts = page.all("#{SUMMARY} button[data-row='action'] code", visible: :all)
    carousel_heads = page.all("#{SUMMARY} button[data-row='heartbeat'] code", visible: :all)
    assert_operator carousel_acts.size, :>=, 7, "expected every soul's act chips in the carousel at #{width}px"
    assert_equal 5, carousel_heads.size, "expected five row-1 heartbeat chips in the carousel at #{width}px"
    assert_every_chip_was_measured(carousel_acts, width)
    assert_chips_readable(carousel_acts, carousel_heads, width, where: "the Workflows summary card's carousel")

    # THE SIDEBAR: opened first, or every chip measures 0x0.
    open_workflows_sidebar
    acts = page.all("#{CARD} button[data-row='action'] code", visible: :all)
    heads = page.all("#{CARD} button[data-row='heartbeat'] code", visible: :all)
    assert_equal carousel_acts.size, acts.size, "the sidebar offers every act the carousel does"
    assert_equal 5, heads.size, "expected five row-1 heartbeat chips in the sidebar at #{width}px"
    assert_every_chip_was_measured(acts, width)
    assert_chips_readable(acts, heads, width, where: "the Workflows sidebar")
  end

  def assert_chips_readable(acts, heads, width, where:)
    broken = acts.filter_map { |c| describe_overflow(c, single_line: true) }
    assert_empty broken,
                 "At a #{width}px viewport these ACT chips in #{where} wrap or are ellipsised. An " \
                 "act is one hyphenated token — split across lines it reads as two commands, and " \
                 "clipped it cannot be read off the card. Reclaim width in tasks/_heartbeat_launcher " \
                 "(the :slide grid or the :row chip column) or tasks/_workflow_copy_chip (padding, font)."

    clipped = heads.filter_map { |c| describe_overflow(c, single_line: false) }
    assert_empty clipped,
                 "At a #{width}px viewport these row-1 phrases in #{where} are CLIPPED. Wrapping onto " \
                 "a second line at a space is fine and expected; losing characters is not."
  end

  # Click the Workflows summary card so the sidebar's chips have real boxes, then wait
  # for them to paint. Without this every sidebar chip measures 0x0.
  #
  # EVERY EXIT HERE IS A FAILURE THAT NAMES ITSELF, and that is the point of the method.
  # A hidden chip measures 0x0, so an opener that never opened would otherwise be
  # REPORTED as a chip that does not fit, and the reader sent to reclaim pixels that were
  # never the problem. An opening timeout and a width regression must never share a
  # message.
  #
  # READINESS SIGNALS, NOT A BIGGER NUMBER. The click is UNORDERED against things that
  # finish on their own schedule, so any fixed wait only moves the threshold:
  #
  #   ALPINE — the card is server-rendered and clickable long before `@click` is bound.
  #            A click that lands first does nothing at all. Alpine strips `x-cloak` from
  #            the sidebar as it initializes it, so the sidebar SHEDDING its cloak is the
  #            hydration signal, and the click waits behind it.
  #   FONTS / THE SCROLL — +click_when_settled+ (application_system_test_case) certifies
  #            the box in the frame the click happens in; the guards above hold that.
  #
  # +wait+ is a per-step ceiling, exposed so the guard test above can drive each exit
  # without paying it four times over.
  def open_workflows_sidebar(wait: OPEN_WAIT)
    unless page.has_selector?(OPENER, wait: wait)
      flunk "the Workflows summary card rendered no opener within #{wait}s, so the sidebar was " \
            "never opened. Either the page never finished loading or the card lost its header row. " \
            "THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    unless page.has_no_selector?("#{SIDEBAR}[x-cloak]", visible: :all, wait: wait)
      flunk "Alpine had not hydrated the Workflows sidebar within #{wait}s — it still carries the " \
            "x-cloak Alpine strips as it initializes. Clicking the opener now would be swallowed " \
            "(@click is not bound yet) and every sidebar chip would stay hidden at 0px. " \
            "THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    click_when_settled(OPENER)

    unless page.has_selector?(OPENED, wait: wait)
      flunk "the Workflows sidebar did not open within #{wait}s of clicking its opener — the card " \
            "reports aria-expanded=#{opener_expanded_state.inspect} (nil means the card lost its " \
            "heading button). The click was swallowed, or the card no longer drives `panel`. " \
            "THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      widths = act_chip_widths
      return if widths.any? && widths.none?(&:zero?)

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "the opener reported the sidebar OPEN but #{widths.count(&:zero?)} of #{widths.size} " \
              "act chips still measured 0px #{wait}s later, so the sidebar never painted. " \
              "THIS IS NOT A VERDICT ABOUT CHIP WIDTH."
      end

      sleep 0.1
    end
  end

  # Load /deployments and hold until the Workflows card and its sidebar are both rendered
  # AND hydrated — the state every scenario in the guard test starts from, so each one
  # breaks exactly the thing it means to break.
  def load_workflows_card
    visit deployments_path
    assert_selector SUMMARY, wait: OPEN_WAIT
    assert_no_selector "#{SIDEBAR}[x-cloak]", visible: :all, wait: OPEN_WAIT
  end

  # An opening failure has to be readable as an OPENER failure by whoever finds it in a
  # CI log, which is two claims, not one: it names the opener, and it cannot be mistaken
  # for the width verdict this file exists to deliver.
  def assert_opening_blames_the_opener(&block)
    error = assert_raises(Minitest::Assertion, &block)

    assert_match(/opener/i, error.message,
                 "an opening that failed must name the opener. Got: #{error.message}")
    assert_match(/NOT A VERDICT ABOUT CHIP WIDTH/, error.message,
                 "an opening that failed must disclaim the width verdict. Got: #{error.message}")
    refute_match(/wrap or are ellipsised|measured 0px wide, which means/, error.message,
                 "an opening that failed must not arrive wearing the width or hidden-chip " \
                 "verdict's words — that confusion is the whole defect this file was fixed for.")
    error
  end

  # What the card currently claims about its sidebar. nil when Alpine never bound the
  # attribute, which separates "never hydrated" from "click swallowed" in the flunk above.
  def opener_expanded_state
    page.evaluate_script(<<~JS)
      (function () {
        var t = document.querySelector("#{SUMMARY} button[data-test='summary-card-toggle']");
        return t ? t.getAttribute('aria-expanded') : null;
      })()
    JS
  end

  # The summary row's RESOLVED track count, read off the rendered grid so it does not
  # depend on class strings — the same reason every other measurement here comes from
  # the rendered box.
  def summary_row_column_count
    page.evaluate_script(<<~JS).to_i
      (function () {
        var row = document.querySelector("[data-test='deploy-summary-row']");
        if (!row) return 0;
        return window.getComputedStyle(row).gridTemplateColumns.split(' ').filter(Boolean).length;
      })()
    JS
  end

  def act_chip_widths
    page.all("#{CARD} button[data-row='action'] code", visible: :all)
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
                 "when this file checked them — not that they fit. This is NOT the opener timing " \
                 "out: open_workflows_sidebar flunks on its own cause if the opener is missing, " \
                 "unhydrated, swallowed the click, or never painted, so by the time this fires " \
                 "something else is hiding these."
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
