require "test_helper"

# The component test renders the partial directly, so it cannot see the layout
# dropping the render line — this request-level assertion is what makes the
# wiring regression-proof.
class SmoothLoadLayoutTest < ActionDispatch::IntegrationTest
  test "[integration] application layout wires the smooth-load metas" do
    get root_path

    assert_response :success
    assert_select "meta[name='view-transition'][content='same-origin']", count: 1
    assert_select "meta[name='turbo-cache-control'][content='no-preview']", count: 1

    # The invariant the whole convention rests on: a duplicate
    # view-transition-name silently disables every transition on the page.
    assert_select "header.vt-pinned-header", count: 1
  end
end
