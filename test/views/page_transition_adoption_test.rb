require "test_helper"

# [component] The hub's adoption of the engine's page transition (studio-engine
# docs/PAGE_TRANSITIONS.md). e2e/page_transitions.spec.js shows what a browser plays.
class PageTransitionAdoptionTest < ActionDispatch::IntegrationTest
  VIEWS = Rails.root.join("app/views")
  CSS = Rails.root.join("app/assets/tailwind/application.css")

  def engine_css
    File.read(File.join(Gem.loaded_specs["studio-engine"].full_gem_path, "app/assets/tailwind/studio_engine/engine.css"))
  end

  test "the hub declares the slide, the one style its pages play" do
    # Found by glob: a spelled path would map this test to every edit of that initializer.
    initializer = Rails.root.join("config", "initializers").glob("stud*.rb").map(&:read).join
    assert_includes initializer, "config.page_transition_style = :slide if config.respond_to?(:page_transition_style=)"
    assert_equal :slide, Studio.page_transition_style if Studio.respond_to?(:page_transition_style)
  end

  test "the body renders the overlay only until the engine's head carries it" do
    get build_path

    assert_response :success
    in_body = css_select("body [data-studio-loader-overlay]").size
    assert_equal(Studio.respond_to?(:loader_overlay) ? 0 : 1, in_body)
  end

  test "the hub moves left, and the head carries one copy of each meta" do
    assert_equal :left, Studio.page_transition_direction

    get build_path

    assert_response :success
    assert_select "meta[name='page-transition-direction'][content='left']", count: 1
    assert_select "meta[name='view-transition'][content='same-origin']", count: 1
    assert_select "meta[name='turbo-cache-control'][content='no-preview']", count: 1
  end

  # A name with no marker floats still over the moving page, and a page's own meta is a second copy.
  test "every inline name in the hub's views carries its marker, and no view renders its own meta" do
    named = Dir[VIEWS.join("**/*.erb")].select { |file| File.read(file).include?("view-transition-name:") }
    assert_operator named.size, :>=, 5, "the scan found the shell's partials"

    named.each do |file|
      source = File.read(file)
      source.scan(/view-transition-name:\s*([\w-]+)/).flatten.each do |name|
        assert_match(/data-vt-morph="#{name}"|vt_morph: "#{name}"/, source, "#{file} names #{name} with no data-vt-morph")
      end
    end

    Dir[VIEWS.join("**/*.erb")].each do |file|
      refute_match(/tag\.meta\(name: "view-transition"/, File.read(file), "#{file}: the engine's smooth_load renders this meta")
    end
  end

  test "the composer and the shell render the name and its marker together" do
    get build_path

    assert_select "[data-test='agent-portrait'][data-vt-morph='agent-portrait'][style*='view-transition-name: agent-portrait']", count: 1
    assert_select "[data-test='agent-shell-status'][data-vt-morph='agent-status'][style*='view-transition-name: agent-status']", count: 1
    assert_select "form#build-first-form[data-vt-morph='agent-composer'][style*='view-transition-name: agent-composer']", count: 1
  end

  # What the deleted app-side rules gave, the engine gives. A later engine that drops one reddens here.
  test "the engine holds the rules the hub's copies were" do
    css = engine_css

    assert_match(/::view-transition-old\(studio-header\),\s*::view-transition-new\(studio-header\)\s*\{\s*animation: none;/, css)
    assert_match(/@media \(prefers-reduced-motion: reduce\)\s*\{\s*::view-transition-group\(\*\),\s*::view-transition-old\(\*\),\s*::view-transition-new\(\*\)\s*\{\s*animation: none !important;/, css)

    hub = File.read(CSS)
    refute_match(/::view-transition-(old|new)\((studio-header|root)\)/, hub)
    assert_match(/::view-transition-group\(agent-portrait\)/, hub, "the agent elements keep their own morph timing")
  end
end
