require "test_helper"

# [component] The engine's /admin/link_preview page as the hub renders it
# (task hub-adopts-link-preview): inside the hub's own layout, with the live card
# drawn from the hub's drafted copy, the words form, and the hub's admin sidebar
# carrying the link that reaches it.
class AdminLinkPreviewPageTest < ActionDispatch::IntegrationTest
  setup do
    Studio::SiteIdentity.bust_cache!
    log_in_as users(:alex)
  end

  test "the live card shows the drafted copy until an operator saves one" do
    get admin_link_preview_path
    assert_response :success

    assert_select "[data-link-preview-page]", 1
    assert_select "[data-link-preview-card-title]", text: "McRitchie Studio"
    assert_select "[data-link-preview-card-description]", text: Studio.site_description
    assert_select "textarea[name='site_identity[description]'][placeholder=?]", Studio.site_description
    assert_select "input[name='site_identity[title]'][placeholder=?]", "McRitchie Studio"
  end

  test "the card shows a saved value over the draft" do
    Studio::SiteIdentity.seed!(title: "Saved Title", description: "Saved description.")

    get admin_link_preview_path
    assert_response :success
    assert_select "[data-link-preview-card-title]", text: "Saved Title"
    assert_select "[data-link-preview-card-description]", text: "Saved description."
  end

  test "the hub's admin sidebar links the page" do
    get admin_link_preview_path
    assert_response :success

    assert_select "a[href='/admin/link_preview']", minimum: 1
  end
end
