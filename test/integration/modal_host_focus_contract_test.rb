# frozen_string_literal: true

require "test_helper"
require "nokogiri"
require_relative "../support/resolved_view"

# [integration] The modal host this app RENDERS must carry the engine's focus
# contract — whichever file that turns out to be.
#
# WHAT CHANGED, AND WHY THIS TEST SURVIVED IT. This app used to ship its own
# app/views/studio/modals/_host.html.erb. studio-engine is NON-ISOLATED, so that
# file SHADOWED the engine's and the engine's host was never rendered here; a gem
# bump delivered none of these fixes and each one had to be ported by hand. This
# test held that port honest. The fork is now deleted and the engine's host is
# what renders (test/views/modal_host_adoption_test.rb owns that proof).
#
# So the premise inverts but the test does not retire, because the failure mode
# does not: re-forking is a one-file mistake that nothing warns about, and the
# cheapest re-fork is a stripped copy missing exactly these bindings. Every
# assertion below therefore reads the RESOLVED host (ResolvedView) rather than a
# path under Rails.root — it describes the file on the page, so it keeps biting
# through a re-fork instead of dying with a missing-file error and being deleted
# as obsolete.
class ModalHostFocusContractTest < ActionDispatch::IntegrationTest
  # The host that ACTUALLY RENDERS, not a path that may or may not be it. Reading
  # Rails.root.join("app/views/studio/modals/_host.html.erb") would assert the
  # fork is CORRECT rather than notice it is THERE — and after the adoption that
  # file does not exist, so a path-based read fails on Errno::ENOENT and looks
  # like the test is obsolete rather than like the wrong question.
  def host_source = ResolvedView.source("host", "studio/modals")

  # THE BACKDROP ELEMENT, parsed out of the RENDERED page.
  #
  # WHY NOT assert_includes ON THE SOURCE — this is the trap the first version of
  # this file fell into, caught by mutation in review. `assert_includes src,
  # "captureFocus"` is a bare substring, and this host DOCUMENTS captureFocus in its
  # own JS comments. Deleting the x-init BINDING left it green. So did deleting the
  # whole captureFocus function. And because those are `//` comments inside <script>,
  # they are emitted into the rendered HTML too — which defeated the "RENDERED, not
  # just source" test written to guard exactly this trap.
  #
  # An attribute on a parsed ELEMENT cannot be satisfied by prose. That is the whole
  # reason for the parser.
  #
  # NOKOGIRI::HTML5, NOT NOKOGIRI::HTML. libxml2 silently DROPS every Alpine event
  # attribute. Measured on this page: the libxml2 parse of this backdrop returns 9
  # attributes, the HTML5 parse returns 11, and the two it loses are
  # @keydown.tab.prevent (the entire tab trap) and @click.self (click-outside
  # dismissal) — it also mangles @keydown.escape.window into a bare `false`
  # attribute. A test on Nokogiri::HTML would report the trap missing, and the
  # tempting next move is to stop asserting it.
  def backdrop
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    node = Nokogiri::HTML5(response.body).at_css('[role="dialog"]')
    assert node, "the rendered page carries no [role=\"dialog\"] backdrop at all — the host " \
                 "partial is not reaching this page, so nothing below proves anything"
    node
  end

  test "the rendered backdrop element carries the whole focus contract" do
    el = backdrop

    assert_equal "-1", el["tabindex"],
                 "the backdrop is not focusable, so captureFocus has nowhere to land that is not " \
                 "a button (a stray Enter would fire it)"
    assert_equal "true", el["aria-modal"], "the dialog does not announce as modal"
    assert_match(/captureFocus\(\$el\)/, el["x-init"].to_s,
                 "the backdrop has no x-init calling captureFocus — the dialog opens with focus " \
                 "still on the page behind it. This is the ORIGINAL measured defect, and the " \
                 "substring version of this assertion could not see it")
    assert_match(/cycleFocus\(\$el, \$event\)/, el["@keydown.tab.prevent"].to_s,
                 "Tab is not intercepted and re-dispatched inside the dialog; native tabbing " \
                 "walks straight out")
    assert_match(/dialogLabel\(\)/, el[":aria-label"].to_s,
                 "the name is computed but never bound to the element — the dialog announces as " \
                 "just \"dialog\"")
  end

  # EVERY FUNCTION THE BACKDROP BINDS MUST EXIST.
  #
  # The element test above proves the WIRING is present; it cannot prove there is
  # anything on the other end of it. Found by mutation: deleting the entire
  # captureFocus FUNCTION leaves every attribute assertion green, because the x-init
  # attribute still reads "$store.modals.captureFocus($el)" — it just points at
  # nothing, and Alpine throws at runtime where no Rails test is looking.
  #
  # The function names are READ OUT of the rendered attributes rather than listed
  # here, so a renamed binding drags its definition along and a new binding is
  # covered the day it is added. Anchored on the DEFINITION form (`name: function(`),
  # which prose cannot satisfy — the whole reason the substring version failed.
  test "every store function the backdrop binds is actually defined" do
    el = backdrop
    src = host_source

    called = %w[x-init @keydown.tab.prevent :aria-label @keydown.escape.window @click.self]
             .flat_map { |a| el[a].to_s.scan(/\$store\.modals\.(\w+)\(/) }
             .flatten.uniq.sort

    assert_operator called.length, :>=, 4,
                    "expected the backdrop to bind at least capture/cycle/label/close, got " \
                    "#{called.inspect} — if the bindings moved, re-point this test"

    called.each do |name|
      assert_match(/\b#{Regexp.escape(name)}: function\s*\(/, src,
                   "the backdrop binds $store.modals.#{name}(), and the store never DEFINES it. " \
                   "The attribute assertions above stay green on this — they prove the wire, not " \
                   "what is on the end of it — and Alpine throws in the browser where no Rails " \
                   "test is looking.")
    end
  end

  # THE FOURTH ENGINE FIX, which this fork missed entirely. The backdrop centres the
  # card with `flex items-center`, so a card taller than the viewport is clipped past
  # BOTH edges with nothing scrollable and its actions unreachable — and on a
  # dismissible: false card escape and click-outside are gated off, so there is no way
  # out at all. It arrived in the engine in the SAME commit as captureFocus.
  test "the rendered card can scroll instead of clipping its own actions away" do
    card = backdrop.at_css("div")

    assert card, "the backdrop renders no card element"
    classes = card["class"].to_s
    assert_includes classes, "max-h-[85dvh]",
                    "the card has no height cap, so a tall card runs past both edges of the " \
                    "viewport (dvh, not vh, so mobile browser chrome counts)"
    assert_includes classes, "overflow-y-auto",
                    "the card is capped but cannot scroll, which is strictly worse: the content " \
                    "below the cap is unreachable rather than merely off-screen"
  end

  # THE SWAP DEFECT the engine's review sent back: a replace keeps current()
  # truthy, so the outer template never re-mounts and x-init never re-runs.
  test "the host re-focuses after a replace" do
    src = host_source

    assert_includes src, "refocus: function",
                    "the host has no refocus() — the trap releases on the first swap"
    # Anchored on a RECEIVER: this file documents refocus() in prose, so a bare
    # /refocus\(\)/ matches the comment and stays green with every call deleted.
    # That exact trap was caught by mutation in the engine.
    #
    # EITHER receiver, because which one is correct is a closure detail, not the
    # contract: the engine calls this.refocus() from a synchronous branch and
    # self.refocus() from inside close()'s setTimeout, where `this` is not the
    # store. Pinning "this." would fail a correct host for writing `var self =
    # this` — and prose still never carries a receiver, so the mutation guard
    # this anchor exists for is untouched.
    assert_match(/\b(?:this|self)\.refocus\(\)/, src,
                 "refocus() is defined but never CALLED, which is the same as not having it")
  end

  test "the host returns focus to the opener when the last dialog closes" do
    src = host_source

    assert_includes src, "releaseFocus",
                    "the host never restores focus, so closing strands the keyboard user"
    assert_match(/\b(?:this|self)\.releaseFocus\(\)/, src,
                 "releaseFocus is defined but never called")
  end

  test "the host names the dialog" do
    src = host_source

    assert_includes src, "dialogLabel",
                    "the dialog has no accessible name — it announces as just 'dialog'"
    assert_match(/:aria-label=/, src, "the name is computed but never bound to the element")
  end

  # WHERE THE RELEASE MAY SIT, AND WHAT MAY GATE IT.
  #
  # turf's fork of this same file nested its release inside the `if (idx >= 0)`
  # REMOVAL guard, so the release was skipped whenever the entry had ALREADY been
  # spliced — press Escape on a dismissible modal, then let clearStaleModals() ->
  # closeAllDismissible() fire from turbo:before-cache inside the exit window, and
  # focus is stranded on a detached backdrop with _returnFocusTo / _backdropEl
  # leaking into the next dialog.
  #
  # REPOINTED, AND THE FIRST REPOINT WAS WRONG — recorded because the wrong one
  # looked better. The old form asserted the call sat at ABSOLUTE brace depth 1:
  # true of the deleted fork, which released synchronously at the top of close(),
  # and false of the engine, which splices after the exit animation and therefore
  # releases from inside a setTimeout callback. Replacing depth with "read the
  # condition attached to the call" passed the engine — and passed a mutant
  # carrying turf's exact defect, because moving the release INTO the removal
  # guard carries its `stack.length === 0` condition in with it. The condition was
  # never where the bug lived; the NESTING was.
  #
  # So measure depth again, but RELATIVE to the innermost enclosing function
  # rather than absolutely. "Top level of the work that close() does" is the
  # property the original meant, and it survives the work moving into a callback.
  # Zero on the engine (release is a sibling of the guard), zero on the deleted
  # fork (no callback at all), one on turf's defect and on the mutant above.
  test "close() releases outside the removal guard, gated only on the stack" do
    body = host_source[/close: function\(\).*?\n        \},/m]

    refute_nil body, "close() moved — re-point this test rather than deleting it"

    release_at = body.index(/\b(?:this|self)\.releaseFocus\(\)/)

    assert release_at, "close() never releases focus, so closing strands the keyboard user"

    # Every brace still open where the release sits, innermost last.
    open_braces = []
    body[0...release_at].each_char.with_index do |ch, i|
      open_braces << i if ch == "{"
      open_braces.pop  if ch == "}"
    end
    fn = open_braces.rindex { |i| body[0...i].match?(/function\s*\([^)]*\)\s*\z/) }

    refute_nil fn, "could not find the function body containing the release — re-point this test"

    nesting = open_braces.length - 1 - fn

    assert_equal 0, nesting,
                 "the release sits #{nesting} block(s) deep inside the nearest function body, " \
                 "so some branch can skip it. The removal is CONDITIONAL — the entry may already " \
                 "have been spliced by a concurrent close — and a release inside that branch is " \
                 "turf's measured defect: focus stranded on a detached backdrop, with " \
                 "_returnFocusTo and _backdropEl leaking into the next dialog."

    # ...and the condition it IS allowed to carry. Both halves are load-bearing:
    # the depth check above catches the release moving INTO the guard, this one
    # catches the guard's test moving ONTO the release where it sits.
    gate = body[/if\s*\(([^)]*)\)\s*\{?\s*(?:this|self)\.releaseFocus\(\)/, 1]

    assert gate,
           "no condition governs the releaseFocus() call — it must not be unconditional, " \
           "or a stacked flow would yank focus out of the dialog still on screen"
    assert_includes gate, "stack.length",
                    "the release is gated on `#{gate.strip}` — the stack being empty is the " \
                    "only condition that belongs here"
    refute_includes gate, "idx",
                    "the release is gated on the REMOVAL outcome (`#{gate.strip}`), so it is " \
                    "skipped whenever the entry was already spliced"
  end
end
