require "test_helper"

class SmoothLoadComponentTest < ActionView::TestCase
  test "[component] opts every page into same-origin view transitions" do
    render partial: "layouts/smooth_load"

    assert_select "meta[name='view-transition'][content='same-origin']", count: 1
  end

  test "[component] disables stale cache previews so navigation renders once" do
    render partial: "layouts/smooth_load"

    assert_select "meta[name='turbo-cache-control'][content='no-preview']", count: 1
  end
end
