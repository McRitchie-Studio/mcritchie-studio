require "test_helper"

# The hub renders the ENGINE's link sidebar (studio-engine 0.30) — its local
# forks are retired. Pins the three legs of the adoption: the config seam hands
# the hub's LinkTreeHelper data to the engine, the local partial forks stay
# deleted so render calls resolve engine-side, and a real page carries the
# engine's own link-sidebar wiring instead of the layout's excised inline copy.
class EngineSidebarAdoptionTest < ActionDispatch::IntegrationTest
  RETIRED_PARTIALS = %w[
    app/views/components/_link_sidebar.html.erb
    app/views/components/_sidebar_panel.html.erb
    app/views/components/_link_sidebar_trigger.html.erb
  ].freeze

  test "local sidebar partial forks stay retired" do
    RETIRED_PARTIALS.each do |path|
      refute Rails.root.join(path).exist?,
             "#{path} exists — the app fork shadows the engine partial and re-opens drift"
    end
  end

  test "config seam hands the view's sidebar_link_sections to the engine" do
    assert Studio.sidebar_sections.respond_to?(:call),
           "sidebar_sections must be the view-context lambda"

    stub = Class.new do
      def sidebar_link_sections = [ { title: "Stub", links: [ { label: "L", href: "/", emoji: "x" } ] } ]
      def admin? = false
    end.new

    assert_equal [ "Stub" ], Studio.sidebar_sections_for(stub).map { |s| s[:title] }
  end

  # The engine ships the link sidebar's wiring in one of two shapes, and a
  # rendered page must carry exactly one of them, whole:
  #
  #   an inline script that sets window.__studioLinkSidebarBridge, or
  #   studio/link_sidebar imported by its own module tag in the head, with the
  #   partial's one link-sidebar controller anchor in the body.
  #
  # Each half is read from where it lives (a script's text, the anchor
  # element), so a stray mention elsewhere on the page satisfies neither.
  test "a rendered page carries the engine's link-sidebar wiring, not the retired inline copy" do
    log_in_as(users(:alex))
    get dashboard_path

    assert_response :success
    inline = css_select("script:not([src])").map { |script| script.text }
    bridge_script = inline.count { |js| js.include?("window.__studioLinkSidebarBridge = true") }
    module_tag = inline.count { |js| js.strip == %(import "studio/link_sidebar") }
    anchors = css_select(%(template[data-studio-controller="link-sidebar"])).size

    as_inline_script = bridge_script == 1 && module_tag.zero? && anchors.zero?
    as_module = bridge_script.zero? && module_tag == 1 && anchors == 1
    assert as_inline_script ^ as_module,
           "expected the engine's link-sidebar wiring in one shape: " \
           "#{bridge_script} inline bridge script(s), #{module_tag} studio/link_sidebar module tag(s), " \
           "#{anchors} controller anchor(s)"
    refute_includes response.body, "__mcritchieLinkSidebarTriggerBridge",
                    "the layout's excised inline bridge is back"
    assert_select "#studio-link-sidebar", 1
  end
end
