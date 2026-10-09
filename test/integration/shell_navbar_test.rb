require "test_helper"

# The page shell is studio-engine's: the header is the engine's navbar
# (layouts/_navbar) with its nav-collapse Stimulus controller, and the account
# controls are the engine's user nav. This app forks neither.
class ShellNavbarTest < ActionDispatch::IntegrationTest
  ENGINE_ROOT = Gem.loaded_specs["studio-engine"].full_gem_path
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  SIDEBAR = "studio-link-sidebar studio-link-sidebar-mobile".freeze

  def resolved(partial, prefix)
    ApplicationController.new.lookup_context.find(partial, [ prefix ], true).identifier
  end

  test "the navbar and the user nav resolve to the engine's partials" do
    assert resolved("navbar", "layouts").start_with?(ENGINE_ROOT), "layouts/_navbar is forked by this app"
    assert resolved("user_nav", "components").start_with?(ENGINE_ROOT), "components/_user_nav is shadowed by this app"

    # Control: the lookup does tell an app partial from an engine one.
    assert resolved("sub_nav", "components").start_with?(Rails.root.to_s)
    refute resolved("sub_nav", "components").start_with?(ENGINE_ROOT)
  end

  test "the layout writes no header of its own" do
    layout = LAYOUT.read

    assert_includes layout, "hub_navbar("
    refute_match(/<header\b/, layout, "the layout draws its own header beside the engine's")
    refute_includes layout, "navCollapse()", "the header binds the Alpine shim, not the engine's controller"
    refute_includes layout, 'render "components/user_nav"'
  end

  test "a visitor gets the engine navbar: brand, sign-in, links menu and theme toggle" do
    get about_path
    assert_response :success

    assert_select "header.nav-shell[data-pin='nav'][data-studio-controller='nav-collapse']", 1 do
      assert_select "a.nav-logo-link[href=?] img.nav-logo[src='/logo-icon.svg']", root_path, 1
      assert_select ".nav-title", text: "McRitchieStudio", count: 1
      assert_select "a.btn-primary[href=?]", login_path, text: Studio.sign_in_label, count: 1
      assert_select "button[data-link-sidebar-trigger][aria-controls=?][aria-label='Toggle links menu']", SIDEBAR, minimum: 1
      assert_select "button[title='Toggle theme']", minimum: 1
      assert_select "a[href=?]", logout_path, count: 0
      assert_select "[data-nav-account]", count: 0
    end
    assert_select "header[x-data='navCollapse()']", count: 0
    assert_select "#studio-link-sidebar", 1
  end

  test "a member gets the account link, the log out link and the links menu" do
    log_in_as users(:viewer)
    get about_path
    assert_response :success

    assert_select "header.nav-shell[data-studio-controller='nav-collapse']", 1 do
      assert_select "a[data-nav-account][href=?] [data-nav-name]", profile_path, text: users(:viewer).display_name, count: 1
      assert_select "a[href=?]", logout_path, text: "Log out", minimum: 1
      assert_select "button[data-link-sidebar-trigger][aria-label='Toggle links menu']", minimum: 1
      assert_select "button[title='Toggle theme']", minimum: 1
      assert_select "a[href=?]", login_path, count: 0
    end
  end

  test "an admin's menu button is the admin menu, with no second cog" do
    log_in_as users(:alex)
    get about_path
    assert_response :success

    assert_select "header.nav-shell" do
      assert_select "button[data-link-sidebar-trigger][aria-label='Toggle admin menu']", minimum: 1
      assert_select "button[data-link-sidebar-trigger][aria-label='Toggle links menu']", count: 0
      assert_select "button[title='Admin']", { count: 0 }, "the engine's admin dropdown draws a second cog beside the sidebar's"
      assert_select "a[data-nav-account][href=?]", profile_path, 1
    end
  end
end
