require "test_helper"

# [component] /contacts: admins only, the tiles and breakdown render the
# dashboard's counts, the filters and search narrow the table, the polled stats
# frame and the row detail frame answer, and the admin sidebar and dashboard link here.
class ContactsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @broadcast = Broadcast.create!(slug: "contacts-page", subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    { "valid@example.com" => "valid", "catch@example.com" => "catch-all", "bad@example.com" => "invalid",
      "trap@example.com" => "spamtrap" }.each do |email, status|
      Contact.create!(email: email, first_name: "Pat", source: "cyvasse", tags: %w[cyvasse-legacy])
             .record_verification!(status: status, sub_status: ("mailbox_not_found" if status == "invalid"))
    end
    @fresh = Contact.create!(email: "fresh@example.com", tags: %w[cyvasse-legacy])
    Contact.create!(email: "news@example.com", tags: %w[newsletter])
    delivery = @broadcast.deliveries.create!(contact: Contact.find_by!(email: "valid@example.com"), sent_at: 1.hour.ago)
    delivery.record_open!
  end

  test "only admins see it, the stats frame, or a contact's detail" do
    [ contacts_path, contacts_stats_path, contact_path(@fresh) ].each do |path|
      get path
      assert_response :redirect, "signed out: #{path}"
    end
    log_in_as(@viewer)
    [ contacts_path, contacts_stats_path, contact_path(@fresh) ].each do |path|
      get path
      assert_redirected_to root_path, "non-admin: #{path}"
    end
  end

  test "a search never writes the address it searched for to the log" do
    log_in_as(@admin)
    get contacts_path(q: "valid@example", query: "kept")
    assert_response :success
    assert_includes request.filtered_path, "q=[FILTERED]"
    assert_includes request.filtered_path, "query=kept", "the filter is anchored to q"
    assert_equal "[FILTERED]", request.filtered_parameters["q"]
  end

  test "the tiles and breakdown show the default list's counts" do
    log_in_as(@admin)
    get contacts_path
    assert_response :success

    assert_select "turbo-frame#contacts-stats[data-poll-url=?]", contacts_stats_path(list: "cyvasse-legacy")
    { total: 5, subscribed: 3, mailable: 1, undeliverable: 2, unverified: 1, emailed: 1 }.each do |key, count|
      assert_select "[data-stat=#{key}] [data-stat-count]", text: count.to_s, message: key.to_s
    end
    { "valid" => 1, "catch-all" => 1, "invalid" => 1, "spamtrap" => 1, "unknown" => 0, "unverified" => 1 }.each do |status, count|
      assert_select "[data-status-count=?]", status, text: count.to_s
    end
    assert_select "[data-reason-count=verification]", text: "2"
    assert_select "[data-verified-pct='80.0']"
    assert_select "[data-last-verified]", text: /Last result/
    assert_select "[data-contact-row]", count: 5
    assert_select "td", text: /mailbox_not_found/
  end

  test "the list filter switches the tiles, and all counts everyone" do
    log_in_as(@admin)
    get contacts_path(list: "all")
    assert_select "[data-stat=total] [data-stat-count]", text: "6"
    get contacts_path(list: "newsletter")
    assert_select "[data-stat=total] [data-stat-count]", text: "1"
    assert_select "[data-last-verified]", text: /No verification has run/
  end

  test "search and filters narrow the table" do
    log_in_as(@admin)
    get contacts_path(q: "CATCH")
    assert_select "[data-contact-row]", count: 1
    assert_select "[data-contact-row] button", text: /catch@example.com/

    get contacts_path(status: "unverified")
    assert_select "[data-contact-row]", count: 1
    assert_select "[data-contact-row] button", text: /fresh@example.com/

    get contacts_path(subscribed: "no")
    assert_select "[data-contact-row]", count: 2
    assert_select "td", text: "Failed verification", count: 2

    get contacts_path(emailed: "yes")
    assert_select "[data-contact-row]", count: 1
    assert_select "[data-result-count]", text: /1 match\b/

    get contacts_path(status: "verified")
    assert_select "[data-result-count]", text: /newest verification first/
  end

  test "the stats frame renders alone for the poll" do
    log_in_as(@admin)
    get contacts_stats_path(list: "all")
    assert_response :success
    assert_select "turbo-frame#contacts-stats"
    assert_select "[data-stat=total] [data-stat-count]", text: "6"
    assert_select "table", count: 0
    assert_no_match(/<html/, response.body)
  end

  test "a row's detail frame lists its deliveries and events" do
    log_in_as(@admin)
    contact = Contact.find_by!(email: "valid@example.com")
    get contact_path(contact)
    assert_response :success
    assert_select "turbo-frame##{ActionView::RecordIdentifier.dom_id(contact, :detail)} [data-contact-detail]"
    assert_select "div", text: "Cyvasse is back"
    assert_select "li", text: /Opened/

    get contact_path(@fresh)
    assert_select "p", text: /No broadcast has been sent/
  end

  test "the admin sidebar and the admin dashboard link to it" do
    log_in_as(@admin)
    get admin_dashboard_path
    assert_select "a[href=?]", contacts_path, text: /Contacts/
    assert_select "a[href=?]", contacts_path, text: /1 verified valid of 6/
    assert_select "a[href=?]", broadcasts_path, text: /Broadcasts/
  end
end
