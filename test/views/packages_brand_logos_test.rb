# frozen_string_literal: true

require "test_helper"

# [component] The brand logos on /packages and /packages/stack in isolation:
# the packages/brand chip (a full-color mark on a light chip, named in its
# tooltip and aria-label, or a text badge when no mark is rendered), the stack
# row that leads with its one brand or a neutral emoji, and the card's
# Powered by row.
#
# Named ...LogosTest so it can never collide with the controller test's class.
class PackagesBrandLogosTest < ActionView::TestCase
  # The stack template asks admin? for its SOP map; a customer sees none.
  setup { view.define_singleton_method(:admin?) { false } }

  test "a brand chip is the rendered mark, named for tooltips and screen readers" do
    render partial: "packages/brand", locals: { key: "heroku", size: :lead }

    assert_select "[data-test='brand-logo'][data-brand='heroku'][data-fallback='false'][title='Heroku'][aria-label='Heroku'][role='img']" do
      assert_select "img[src*='workspace_icons/brand/heroku']"
    end
    assert_select "[data-test='brand-logo'].bg-white", 1, "a light chip so dark marks read in dark mode"
  end

  test "a brand with no rendered mark falls back to a text badge, never a broken image" do
    render partial: "packages/brand", locals: { key: "logrocket", size: :chip }

    assert_select "[data-test='brand-logo'][data-brand='logrocket'][data-fallback='true'][aria-label='Logrocket']", text: "Lo"
    assert_select "img", 0
  end

  test "every stack row leads with its brand or a neutral icon, and strips its other brands" do
    @packages = WorkspacePackage.all
    render template: "packages/stack"

    WorkspacePackage.features.each do |feature|
      row = "[data-test='stack-row'][data-feature='#{feature.name.parameterize}']"
      assert_select "#{row} [data-test='stack-lead'][data-lead='#{feature.brand || 'emoji'}']", 1, feature.name
      assert_equal feature.strip_brands, css_select("#{row} [data-test='stack-software'] [data-test='brand-logo']").map { |l| l["data-brand"] },
                   "#{feature.name} strip"
    end
    assert_select "[data-feature='server'] [data-test='stack-lead'] [data-brand='heroku'] img"
    assert_select "[data-feature='hosting-mode'] [data-test='stack-lead'][data-lead='emoji']", text: "🏷️"
    assert_select "[data-feature='custom-connectors'] [data-test='coming-soon']"
    assert_select "[data-feature='custom-connectors'] [data-brand='egnyte']"
  end

  test "on a phone the feature column narrows and row descriptions hide" do
    @packages = WorkspacePackage.all
    render template: "packages/stack"

    assert_select "thead th.pkg-sticky-col.w-32.sm\\:w-44"
    assert_select "[data-test='stack-blurb'].hidden.md\\:block", WorkspacePackage.features.size
  end

  test "each card's Powered by row draws the brands its tier adds" do
    @packages = WorkspacePackage.all
    render template: "packages/index"

    previous = nil
    @packages.each do |package|
      expected = package.card_brands(previous)
      assert_equal expected, css_select("[data-test='package-powered-by'][data-package='#{package.key}'] [data-test='brand-logo']").map { |l| l["data-brand"] }
      previous = package
    end
  end
end
