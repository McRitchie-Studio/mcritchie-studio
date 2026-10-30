# frozen_string_literal: true

require "test_helper"

# [component] Task hub-adopts-type-scale: an admin-only page reads the type
# scale's 14px dense base, through `type-dense` on <body> (on <html> the theme
# tag's unlayered :root rule would win); a visitor's page and a signed-in
# customer's own pages keep the 16px base. The theme tag carries the studio
# kit's four settings either way.
class AdminTypeDenseTest < ActionDispatch::IntegrationTest
  def body_classes = css_select("body").first["class"].split

  test "an admin page puts type-dense on body, not html" do
    log_in_as(users(:alex))
    get tasks_path
    assert_response :success
    assert_includes body_classes, "type-dense"
    refute_includes css_select("html").first["class"].to_s.split, "type-dense"
  end

  test "a public page keeps the 16px base" do
    get root_path
    assert_response :success
    refute_includes body_classes, "type-dense"
  end

  test "a signed-in customer's own page keeps the 16px base" do
    log_in_as(users(:viewer))
    get profile_path
    assert_response :success
    refute_includes body_classes, "type-dense"
  end

  test "the theme tag carries the studio kit's type scale" do
    get root_path
    assert_includes response.body, "--type-base: 16px;"
    assert_includes response.body, "--type-dense-base: 14px;"
    assert_includes response.body, "--type-display-weight: 800;"
    assert_includes response.body, "--type-text-weight: 300;"
  end
end
