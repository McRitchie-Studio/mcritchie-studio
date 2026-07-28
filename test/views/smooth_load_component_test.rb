require "test_helper"

# The smooth-load metas render from the ENGINE partial (studio-engine 0.24)
# behind the Studio.smooth_load toggle — the app-local copy is deleted. The
# integration tier (test/integration/smooth_load_layout_test.rb) proves the
# layout wires it; this tier proves the engine partial honors the toggle.
class SmoothLoadComponentTest < ActionView::TestCase
  test "[component] enabled: opts every page into same-origin view transitions" do
    with_smooth_load(true) do
      render partial: "layouts/studio/smooth_load"

      assert_select "meta[name='view-transition'][content='same-origin']", count: 1
    end
  end

  test "[component] enabled: disables stale cache previews so navigation renders once" do
    with_smooth_load(true) do
      render partial: "layouts/studio/smooth_load"

      assert_select "meta[name='turbo-cache-control'][content='no-preview']", count: 1
    end
  end

  test "[component] disabled: renders neither meta" do
    with_smooth_load(false) do
      render partial: "layouts/studio/smooth_load"

      assert_select "meta[name='view-transition']", count: 0
      assert_select "meta[name='turbo-cache-control']", count: 0
    end
  end

  private

  # Studio.smooth_load is a mattr_accessor (process-global), so always restore
  # the app's configured value — leaking a toggle would flip every later test.
  def with_smooth_load(value)
    original = Studio.smooth_load
    Studio.smooth_load = value
    yield
  ensure
    Studio.smooth_load = original
  end
end
