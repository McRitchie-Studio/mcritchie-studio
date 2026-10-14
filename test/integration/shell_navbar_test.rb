require "test_helper"
require_relative "../support/navbar_brand"

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
      # The saved kit (public/brand): its icon beside the words, or its lockup
      # once the engine draws Studio.navbar_wordmark (test/support/navbar_brand.rb).
      if NavbarBrand.wordmark?
        assert_select "a.nav-logo-link[href=?] img.nav-wordmark-dark[src='/brand/navbar-dark.svg']", root_path, 1
      else
        assert_select "a.nav-logo-link[href=?] img.nav-logo[src='/brand/icon-light.svg']", root_path, 1
      end
      NavbarBrand.assert_drawn(self)
      assert_select "a.btn-primary[href=?]", login_path, text: Studio.sign_in_label, count: 1
      assert_select "button[data-link-sidebar-trigger][aria-controls=?][aria-label='Toggle links menu']", SIDEBAR, minimum: 1
      assert_select "button[title='Toggle theme']", minimum: 1
      assert_select "a[href=?]", logout_path, count: 0
      assert_select "[data-nav-account]", count: 0
      assert_select "[data-nav-phone-name], .nav-phone-tools", count: 0
    end
    assert_select "header[x-data='navCollapse()']", count: 0
    assert_select "#studio-link-sidebar", 1
  end

  test "a member gets the account link by first name and the links menu, with no log out link" do
    log_in_as users(:viewer)
    get about_path
    assert_response :success
    # The engine's resolver, not a literal: this app's own CI bundles the
    # released gem, and the engine's consumer lane bundles its checkout. The
    # engine's unit suite pins "Viewer User" -> "Viewer".
    first_name = Studio.navbar_user_name_for(users(:viewer))

    assert_select "header.nav-shell[data-studio-controller='nav-collapse']", 1 do
      assert_select "a[data-nav-account][href=?] [data-nav-name]", profile_path, text: first_name, count: 1
      # Log out lives in the link sidebar; the navbar drew a second copy.
      assert_select "a[href=?]", logout_path, count: 0
      assert_select "button[data-link-sidebar-trigger][aria-label='Toggle links menu']", minimum: 1
      assert_select "button[title='Toggle theme']", minimum: 1
      assert_select "a[href=?]", login_path, count: 0
      # A phone draws the name beside the avatar; the account link names it for assistive tech.
      assert_select "[data-nav-phone-name][aria-hidden='true']", text: first_name, count: 1
      assert_select ".nav-phone-tools button[data-link-sidebar-trigger]", 1
      assert_select ".nav-phone-tools button[title='Toggle theme']", 1
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
