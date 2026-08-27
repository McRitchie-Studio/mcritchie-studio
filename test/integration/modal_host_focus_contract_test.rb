# frozen_string_literal: true

require "test_helper"

# [integration] This app's FORK of the modal host must carry the engine's focus
# contract.
#
# WHY A TEST HERE, when the engine already has one. studio-engine is
# NON-ISOLATED, so an app view SHADOWS the engine view of the same path. This app
# ships its own app/views/studio/modals/_host.html.erb, so the engine's file is
# NEVER RENDERED here — a gem bump delivers none of these fixes. Verified before
# porting: the fork carried no captureFocus, no tabindex=-1, no tab trap, no
# cycleFocus and no dialogLabel. Only _scoped_host, which is unforked,
# propagates from the engine.
class ModalHostFocusContractTest < ActionDispatch::IntegrationTest
  HOST = "app/views/studio/modals/_host.html.erb"

  def host_source = File.read(Rails.root.join(HOST))

  test "the forked host traps focus on open" do
    src = host_source

    assert_includes src, "captureFocus",
                    "the fork does not capture focus on open — the dialog opens with focus still " \
                    "on the page behind it"
    assert_includes src, 'tabindex="-1"',
                    "the backdrop is not focusable, so captureFocus has nowhere to land that is " \
                    "not a button (a stray Enter would fire it)"
    assert_includes src, "keydown.tab.prevent",
                    "Tab is not intercepted; native tabbing walks straight out of the dialog"
    assert_includes src, "cycleFocus",
                    "Tab is intercepted but nothing re-dispatches it inside the dialog"
  end

  # THE SWAP DEFECT the engine's review sent back: a replace keeps current()
  # truthy, so the outer template never re-mounts and x-init never re-runs.
  test "the forked host re-focuses after a replace" do
    src = host_source

    assert_includes src, "refocus: function",
                    "the fork has no refocus() — the trap releases on the first swap"
    # Anchored on the RECEIVER: this file documents refocus() in prose, so a bare
    # /refocus\(\)/ matches the comment and stays green with every call deleted.
    # That exact trap was caught by mutation in the engine.
    assert_match(/this\.refocus\(\)/, src,
                 "refocus() is defined but never CALLED, which is the same as not having it")
  end

  test "the forked host returns focus to the opener when the last dialog closes" do
    src = host_source

    assert_includes src, "releaseFocus",
                    "the fork never restores focus, so closing strands the keyboard user"
    assert_match(/this\.releaseFocus\(\)/, src, "releaseFocus is defined but never called")
  end

  test "the forked host names the dialog" do
    src = host_source

    assert_includes src, "dialogLabel",
                    "the dialog has no accessible name — it announces as just 'dialog'"
    assert_match(/:aria-label=/, src, "the name is computed but never bound to the element")
  end

  # RENDERED, not just present in source: a fix inside a branch that never runs
  # scans clean and reaches the browser as nothing.
  test "the wiring survives rendering into a real page" do
    html = ActionController::Base.render(partial: "studio/modals/host")

    assert_includes html, "captureFocus", "the focus wiring did not reach the rendered host"
    assert_includes html, 'tabindex="-1"'
    assert_match(/this\.refocus\(\)/, html)
  end
end
