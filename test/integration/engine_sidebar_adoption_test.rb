require "test_helper"

# The hub renders the ENGINE's link sidebar (studio-engine 0.30) — its local
# forks are retired. Pins the three legs of the adoption: the config seam hands
# the hub's LinkTreeHelper data to the engine, the local partial forks stay
# deleted so render calls resolve engine-side, and a real page carries the
# engine-owned store bridge instead of the layout's excised inline copy.
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

  test "a rendered page carries the engine store bridge, not the retired inline copy" do
    log_in_as(users(:alex))
    get dashboard_path

    assert_response :success
    assert_includes response.body, "__studioLinkSidebarBridge",
                    "engine bridge must ride components/link_sidebar"
    refute_includes response.body, "__mcritchieLinkSidebarTriggerBridge",
                    "the layout's excised inline bridge is back"
    assert_includes response.body, %(id="studio-link-sidebar")
  end
end
