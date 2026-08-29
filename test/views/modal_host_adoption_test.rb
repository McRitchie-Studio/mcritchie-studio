# frozen_string_literal: true

require "test_helper"
require_relative "../support/resolved_view"

# [component] This app renders the ENGINE's modal host, not a copy.
#
# It shipped its own 228-line fork of app/views/studio/modals/_host.html.erb.
# studio-engine is NON-ISOLATED and does not prepend_view_path, so that file
# WON the lookup and the engine's host was never rendered here — which is how
# the fork went unnoticed for months while the engine's grew to 855 lines.
#
# Deleting it is a PURE UPGRADE, not a trade. Measured on the two files at
# adoption — fork 228 lines against studio-engine 0.65.2's 855 — the fork carried
# ZERO occurrences of ModalAnimations (engine 13), cardClasses (6) and
# CARD_WIDTHS (8). Every modal in this app was a fixed max-w-sm with no animation
# registry and no per-modal width. The fork defined no store function the engine
# lacks; in the browser the adopted store answers to all fifteen.
#
# The engine-side counts are stamped with the version they were taken from
# BECAUSE THEY MOVE — an earlier pass recorded 12/6/7 against 0.65.1 and the
# 0.65.2 bump made that prose quietly wrong. What does not move, and is the
# actual claim, is the fork's zero.
class ModalHostAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  FORK   = Rails.root.join("app/views/studio/modals/_host.html.erb")

  test "the host RESOLVES outside this app" do
    # THE ACCEPTANCE PROOF, and the only assertion here that cannot be faked by
    # tidying the repo. Rendering `studio/modals/host` proves nothing on its own
    # — that is the exact line the fork was serving. Resolving it does.
    identifier = ResolvedView.resolve("host", "studio/modals")

    assert ResolvedView.shadow_free?(identifier),
           "the modal host must resolve to the engine, not to a local file under " \
           "#{Rails.root.join('app/views')} — a shadowing fork is exactly what this " \
           "test exists to catch (resolved: #{identifier})"
  end

  test "the fork file is gone, not merely unregistered" do
    # Unregistering is not enough and the distinction is not pedantic: the
    # lookup is by PATH, so a file left on disk at the shadow path is still the
    # file that renders, whatever any layout says.
    refute File.exist?(FORK),
           "#{FORK} still exists — while it does, it SHADOWS the engine host regardless " \
           "of what the layout registers"
  end

  test "the layout still registers the host and hands it a slot" do
    # COMMENTS STRIPPED FIRST, and this file of all files should have done so.
    # Its own header declares "EVERY ANCHOR HERE IS A FORM PROSE CANNOT TAKE" —
    # this was the one anchor that could. Proven, not argued: replacing the whole
    # render block with `<%# render "studio/modals/host" do — removed %>` left
    # this test GREEN while the host vanished from every page. Mirrors markup_of
    # in layer_scale_adoption_test.rb.
    layout = LAYOUT.read.gsub(/<%#.*?%>/m, " ")

    assert_includes layout, %(render "studio/modals/host" do),
                    "the host must be rendered WITH A BLOCK — its per-callsite modal " \
                    "registrations are passed as the slot"
  end

  # A SIBLING PARTIAL AS THE CONTROL.
  #
  # Without this, the resolution test above has a silent failure mode: if the
  # lookup itself were broken (a bad prefix, a renamed template) every path it
  # returned would be non-local and the assertion would pass for the wrong
  # reason. _scoped_host has never been forked in this app, so it must ALSO
  # resolve to the engine — and if the two disagree, the lookup is fine and the
  # host is genuinely the odd one out.
  test "an unforked sibling resolves the same way" do
    scoped = ResolvedView.resolve("scoped_host", "studio/modals")

    assert ResolvedView.shadow_free?(scoped),
           "scoped_host is not forked in this app and must resolve to the engine; if this " \
           "fails the lookup is broken, not the host adoption (resolved: #{scoped})"
    assert_equal File.dirname(scoped),
                 File.dirname(ResolvedView.resolve("host", "studio/modals")),
                 "the host and its unforked sibling must come from the SAME directory — " \
                 "if they diverge, one of them is being shadowed"
  end

  # Both install modes are legitimate, and the predicate must accept BOTH.
  # These identifiers are not invented: the first is what this app resolves today
  # (studio-engine from RubyGems, verified against the running app), the second is
  # the literal path from the studio-engine consumer-CI run that red-sealed the
  # 0.65.1 gem publish, where the engine is bundled as a path checkout.
  test "the resolution check accepts a gem install AND a path checkout" do
    gem_install   = "/opt/homebrew/lib/ruby/gems/3.3.0/gems/studio-engine-0.65.2" \
                    "/app/views/studio/modals/_host.html.erb"
    path_checkout = "/home/runner/work/studio-engine/studio-engine/studio" \
                    "/app/views/studio/modals/_host.html.erb"

    assert ResolvedView.shadow_free?(gem_install), "a gem install must pass"
    assert ResolvedView.shadow_free?(path_checkout),
           "a path checkout must pass — asserting on \"/gems/\" is what red-sealed the " \
           "engine's own release"

    refute ResolvedView.shadow_free?(FORK.to_s),
           "the predicate must still reject the local fork it exists to reject"
  end

  # THE CAPABILITY THE HUB GAINS, asserted on the file that actually renders.
  # Not decoration: these three are the seams the fork had none of, and naming
  # them here means a silent re-fork to a stripped copy fails on capability as
  # well as on resolution.
  #
  # EVERY ANCHOR HERE IS A FORM PROSE CANNOT TAKE, and that is not a stylistic
  # preference — it is the one thing this test got wrong, caught by mutation.
  # The animation anchor was a bare /ModalAnimations/, and this host NAMES the
  # registry nine times in its own header and `//` comments against four times
  # in code. A mutant that stripped the registry outright — no merge, no
  # late-binding read — and kept the header prose stayed GREEN. A stripped
  # re-fork is exactly the shape that copies the header and drops the body, so
  # the assertion was blind to the case it exists for. An assignment, a `&&`,
  # and a `name: function` are all things the documentation never writes.
  test "the adopted host brings the registry seams the fork never had" do
    src = ResolvedView.source("host", "studio/modals")

    assert_match(/CARD_WIDTHS\s*&&/, src,
                 "the host must RESOLVE a per-modal width from the CARD_WIDTHS registry; " \
                 "the fork hardcoded max-w-sm on the card element")
    assert_match(/cardClasses:\s*function/, src,
                 "cardClasses() is what applies the width and the animation classes")
    assert_match(/window\.ModalAnimations\s*=\s*\{/, src,
                 "the per-modal enter/exit animation registry is the third seam, and it must be " \
                 "BUILT here — the consumer extension point is an app defining " \
                 "window.ModalAnimations first and the host merging its own defaults over it, " \
                 "so the assignment is the seam. Naming the registry in a comment is not it.")
  end
end
