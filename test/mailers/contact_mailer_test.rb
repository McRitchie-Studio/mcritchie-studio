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
end
