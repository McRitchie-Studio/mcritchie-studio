# frozen_string_literal: true

require "test_helper"

# [component] The hub renders the ENGINE's environment banner and keeps no fork
# of its own (studio-engine >= 0.30).
#
# The rules the banner applies are the engine's to test — and are, in
# studio-engine test/lib/studio/environment_banner_test.rb. What only this repo
# can assert is the adoption seam: that the layout delegates, that the host
# copies are really gone, and that nothing crept back.
class EnvironmentBannerAdoptionTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")

  # The adoption seam MOVED, and the assertion moved with it. This task replaces the
  # single environment banner with the engine's bar STACK: bars compose independently
  # and the header offsets itself by however many render, so the layout now delegates
  # to `studio/banners/stack` (which renders the environment bar among them) instead
  # of naming that one bar directly. Asserting the old partial would now demand the
  # hub keep a seam this task deliberately retired.
  test "the layout renders the shared engine bar stack" do
    layout = LAYOUT.read
    assert_includes layout, %(render "studio/banners/stack"),
      "the layout delegates to the engine's bar stack"
    refute_includes layout, %(render "studio/banners/environment"),
      "and no longer names a single bar — the stack owns which bars render"
  end

  # The deleted fork is the point of the task: two hand-maintained copies of
  # buttons the engine already ships, which is how the hub and turf-monster
  # drifted apart in the first place.
  test "no host fork of the banner buttons survives" do
    %w[
      app/views/shared/_email_status_button.html.erb
      app/views/shared/_dev_mode_button.html.erb
    ].each do |path|
      assert_not Rails.root.join(path).exist?, "#{path} should have moved into studio-engine"
    end

    assert_not_includes LAYOUT.read, "shared/email_status_button"
    assert_not_includes LAYOUT.read, "shared/dev_mode_button"
  end

  # The host used to decide this. Delegating it is the whole adoption — a
  # conditional creeping back would silently re-fork the show rule.
  test "the layout wraps the banner in no conditional of its own" do
    assert_not_includes LAYOUT.read, "show_environment_banner?"
    assert_not_includes LAYOUT.read, "environment_banner_message"
  end

  test "the removed helpers are gone from ApplicationHelper" do
    %i[qa_environment? show_environment_banner? environment_banner_message].each do |method|
      assert_not ApplicationHelper.method_defined?(method),
                 "ApplicationHelper##{method} moved to Studio in studio-engine 0.30"
    end
  end

  # The engine methods the layout now leans on must actually be there — this is
  # what a too-low gem pin would break, and it would break at request time.
  test "the engine supplies the banner contract this app now depends on" do
    %i[qa_environment? show_environment_banner? environment_banner_message local_inbox_reachable?].each do |method|
      assert Studio.respond_to?(method), "studio-engine >= 0.30 must define Studio.#{method}"
    end
  end

  # End to end: the banner really renders on a real response in this env.
  test "a rendered page carries the banner" do
    get root_path

    assert_response :success
    assert_select "a[href='/_studio/local_emails']", minimum: 1
    assert_includes response.body, "#{Rails.env.capitalize} Environment"
  end
end
