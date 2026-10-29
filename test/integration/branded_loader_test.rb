require "test_helper"

# [integration] The hub adopts studio-engine's branded loader (docs/LOADER.md in
# the engine; task branded-app-loader): Sparkle on the Studio kit's own icon,
# the page-load overlay in the layout, and the pending state in /build's send
# button.
#
# GUARDED, like the hub's other engine settings: the
# initializer and the views switch on only once the release relocks an engine
# that has the loader. Each test asserts the adopted shape on such an engine,
# and the guard (nothing renders, nothing raises) on an older one.
class BrandedLoaderTest < ActionDispatch::IntegrationTest
  LOADER_ENGINE = Studio.respond_to?(:loader=)
  ART = Rails.root.join("public/brand/loader-sparkle.svg")
  ICON = Rails.root.join("public/brand/icon-dark.svg")

  test "the hub's loader is Sparkle on the violet kit icon" do
    if LOADER_ENGINE
      assert_equal({ style: :sparkle, icon: "/brand/icon-dark.svg", art: "/brand/loader-sparkle.svg" }, Studio.loader)
      art = Studio::Loader.art(Studio.loader[:art], :sparkle)
      assert art, "the art file parses and carries spark layers"
      assert_equal 5, art[:layers].size, "the kit icon has five sparkles"
    else
      # An engine without the loader: the guarded setting stays inert, and the
      # art it will name is already in place.
      assert ART.file?, "the art the setting names ships with the hub"
    end
  end

  test "the sparkle art shares the icon's viewBox and its sparks are cut from it" do
    view_box = ->(svg) { svg[/viewBox="([^"]+)"/, 1] }
    art = ART.read
    icon = ICON.read

    assert_equal view_box.call(icon), view_box.call(art), "the layers would not sit on the icon"
    sparks = art.scan(/data-loader="spark" d="([^"]+)"/).flatten
    assert_equal 5, sparks.size
    sparks.each { |d| assert_includes icon, d, "a spark that is not the icon's own" }
  end

  test "every page carries the hidden page-load overlay, once" do
    get about_path
    assert_response :success

    if LOADER_ENGINE
      assert_select "[data-studio-loader-overlay][hidden]", 1 do
        assert_select ".studio-loader[data-loader-style='sparkle'] img.studio-loader-icon[src='/brand/icon-dark.svg']"
        assert_select ".studio-loader path.studio-loader-sparkle", 5
      end
    else
      assert_select "[data-studio-loader-overlay]", 0
    end
  end

  test "the build send button carries the pending loader beside its arrow" do
    get build_path
    assert_response :success

    if LOADER_ENGINE
      assert_select "button[data-build-first-send]", 1 do
        assert_select "svg[data-loader-idle]", 1
        assert_select ".studio-loader[data-loader-pending][aria-hidden='true']", 1
      end
    else
      assert_select "button[data-build-first-send] .studio-loader", 0
    end
  end
end
