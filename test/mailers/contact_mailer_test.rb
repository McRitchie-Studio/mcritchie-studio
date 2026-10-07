require "test_helper"

# [unit] ContactMailer — the operator's notice of a /contact submission.
class ContactMailerTest < ActionMailer::TestCase
  def submission(**attrs)
    ContactSubmission.create!({ name: "Jordan Lee", email: "jordan@example.com", message: "Line one\nLine two" }.merge(attrs))
  end

  test "goes to Alex, replies to the visitor, and names them in the subject" do
    mail = ContactMailer.submission(submission)

    assert_equal ["alex@mcritchie.studio"], mail.to
    assert_equal ["jordan@example.com"], mail.reply_to
    assert_equal "Contact form: Jordan Lee", mail.subject
  end

  test "both parts carry the message, the number and the consent answer" do
    mail = ContactMailer.submission(submission(phone: "303-555-0142", sms_care_consent: true))

    [mail.html_part.body.to_s, mail.text_part.body.to_s].each do |body|
      assert_includes body, "jordan@example.com"
      assert_includes body, "303-555-0142"
      assert_includes body, "Consented to customer care text messages"
      assert_includes body, "Line two"
      assert_includes body, ContactSubmission::DISCLOSURE_VERSION
    end
  end

  test "a decline is stated plainly so nobody texts the number" do
    mail = ContactMailer.submission(submission(sms_declined: true))

    assert_includes mail.text_part.body.to_s, "Declined all text messages"
    assert_includes mail.text_part.body.to_s, "Mobile: not given"
  end

  test "a visitor's markup is escaped in the HTML part" do
    mail = ContactMailer.submission(submission(message: "<script>alert(1)</script>"))

    refute_includes mail.html_part.body.to_s, "<script>"
  end

  # --- the daily digest of flagged submissions ---------------------------------

  test "the digest lists flagged rows from the window and never an unflagged one" do
    submission(name: "Real Person", email: "real@example.com")
    bot = submission(name: "RobertniB", email: "bot@example.com", spam_reason: "no_browser_proof", message: "price?")
    old = submission(name: "Last Week", spam_reason: "too_fast")
    old.class.where(id: old.id).update_all(created_at: 3.days.ago)

    mail = ContactMailer.flagged_digest(1.day.ago.iso8601)

    assert_equal ["alex@mcritchie.studio"], mail.to
    assert_equal "Contact form: 1 flagged as spam in the last day", mail.subject
    [mail.html_part.body.to_s, mail.text_part.body.to_s].each do |body|
      assert_includes body, "##{bot.id}"
      assert_includes body, "bot@example.com"
      assert_includes body, "no_browser_proof"
      assert_includes body, "price?"
      refute_includes body, "real@example.com"
      refute_includes body, "Last Week"
      refute_includes body, "more not listed"
    end
  end

  test "the digest caps the list and counts the rest" do
    (ContactMailer::DIGEST_LIMIT + 2).times { |i| submission(name: "Bot#{i}", spam_reason: "too_fast") }

    mail = ContactMailer.flagged_digest(1.day.ago.iso8601)

    assert_equal "Contact form: #{ContactMailer::DIGEST_LIMIT + 2} flagged as spam in the last day", mail.subject
    body = mail.text_part.body.to_s
    assert_equal ContactMailer::DIGEST_LIMIT, body.scan(/· too_fast/).size
    assert_includes body, "…and 2 more not listed."
  end
end
