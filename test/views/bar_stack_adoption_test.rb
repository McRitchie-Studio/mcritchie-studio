# frozen_string_literal: true

require "test_helper"

# [component] The hub renders the engine's bar STACK as its header's sibling
# (studio-engine >= 0.33), and offsets the header by the height the stack
# publishes.
#
# The stack's own behaviour is the engine's to test, and is tested there. What
# only this repo can assert is the adoption seam: that the banner is no longer
# nested inside the header, that the header stopped hardcoding its offset, and
# that the page still has exactly one pinned header.
class BarStackAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

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

  test "the header offsets by the published height instead of hardcoding top-0" do
    assert_includes LAYOUT.read, "top:var(--studio-bars-h, 0px)"
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

  test "a rendered page carries the bars and the offset" do
    get root_path

    assert_response :success
    assert_includes response.body, "studio-bar-stack"
    # The PUBLICATION, not the reference. The header's own style attribute puts
    # "--studio-bars-h" in every response unconditionally, so matching the bare
    # name passes even when the stack renders nothing at all.
    assert_includes response.body, ":root{--studio-bars-h:",
                    "the stack must publish the height on :root, not merely be referenced"

    header = css_select("header.vt-pinned-header").first
    assert_not_nil header
    # The property, not one spelling of it: re-adding top-0 further along the class
    # list, or reordering the classes, both slip past a substring refutation.
    assert_no_match(/\btop-\S/, header["class"].to_s,
                    "a top-* utility would fight the offset the stack publishes")
    assert_includes header["style"].to_s, "top:var(--studio-bars-h, 0px)"
    assert_select "a[href='/_studio/local_emails']", minimum: 1
  end
end
