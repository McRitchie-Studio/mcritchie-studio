require "test_helper"

# [unit] The /contacts table: search, each filter, ordering and the rollups.
class Contacts::DirectoryTest < ActiveSupport::TestCase
  setup do
    @broadcast = Broadcast.create!(slug: "dir-test", subject: "Hello", template_key: "cyvasse_is_back")
    @old_valid = Contact.create!(email: "old.valid@example.com", tags: %w[cyvasse-legacy])
    @old_valid.record_verification!(status: "valid", at: 3.hours.ago)
    @new_invalid = Contact.create!(email: "new.invalid@gmail.com", tags: %w[cyvasse-legacy])
    @new_invalid.record_verification!(status: "invalid", at: 1.hour.ago)
    @fresh = Contact.create!(email: "fresh@example.com", tags: %w[cyvasse-legacy])
    @elsewhere = Contact.create!(email: "elsewhere@example.com", tags: %w[newsletter])

    delivery = @broadcast.deliveries.create!(contact: @old_valid, sent_at: 2.hours.ago)
    delivery.record_open!(at: 90.minutes.ago)
    delivery.record_open!(at: 30.minutes.ago)
    delivery.record_open!(source: "resend", at: 5.minutes.ago) # Resend's opens are not ours
    delivery.record_click!(link_key: "play", at: 20.minutes.ago)
  end

  def emails(params = {}) = Contacts::Directory.new(params).rows.map { |r| r.contact.email }

  test "defaults to the cyvasse-legacy list, newest contact first" do
    assert_equal %w[fresh@example.com new.invalid@gmail.com old.valid@example.com], emails
    assert_includes emails(list: "all"), "elsewhere@example.com"
  end

  test "search matches part of an email, case-insensitively, and escapes LIKE" do
    assert_equal %w[new.invalid@gmail.com], emails(q: "GMAIL")
    assert_empty emails(q: "%")
  end

  test "each filter narrows" do
    assert_equal %w[fresh@example.com old.valid@example.com], emails(subscribed: "yes")
    assert_equal %w[new.invalid@gmail.com], emails(subscribed: "no")
    assert_equal %w[old.valid@example.com], emails(status: "valid")
    assert_equal %w[fresh@example.com], emails(status: "unverified")
    assert_equal %w[old.valid@example.com], emails(emailed: "yes")
    assert_equal %w[fresh@example.com new.invalid@gmail.com], emails(emailed: "no")
  end

  test "a verified filter orders by the newest verification" do
    assert_equal %w[new.invalid@gmail.com old.valid@example.com], emails(status: "verified")
    assert Contacts::Directory.new(status: "verified").verified_order?
    refute Contacts::Directory.new(status: "unverified").verified_order?
  end

  test "rows carry sends and the latest open and click from our own tracking" do
    row = Contacts::Directory.new(q: "old.valid").rows.sole
    assert_equal 1, row.sent
    assert_in_delta 30.minutes.ago, row.last_opened_at, 2
    assert_in_delta 20.minutes.ago, row.last_clicked_at, 2
    assert_nil Contacts::Directory.new(q: "fresh").rows.sole.last_opened_at
  end

  test "pages by PER_PAGE" do
    stub_const(Contacts::Directory, :PER_PAGE, 2) do
      assert_equal 2, Contacts::Directory.new.pages
      assert_equal %w[old.valid@example.com], emails(page: 2)
    end
  end

  private

  def stub_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end
end
