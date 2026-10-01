require "test_helper"

# [unit] ContactSubmission — the /contact form's proof-of-consent record. The
# consent rules are what a carrier audits, so each is pinned: nothing defaults
# to consent, No excludes Yes, the phone is needed only with a Yes, and the
# disclosure stored is the server's wording, never the form's.
class ContactSubmissionTest < ActiveSupport::TestCase
  def build(**attrs)
    ContactSubmission.new({ name: "Jordan Lee", email: "jordan@example.com", message: "Hello there" }.merge(attrs))
  end

  test "name, email and message are enough; nothing defaults to consent" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence

    refute row.sms_care_consent
    refute row.sms_marketing_consent
    refute row.sms_declined
    refute row.sms_consent?
    assert_nil row.phone
    assert_equal "No answer (no consent given)", row.consent_summary
  end

  test "a visitor can decline every text message without a phone number" do
    row = build(sms_declined: true)

    assert row.valid?, row.errors.full_messages.to_sentence
    assert_equal "Declined all text messages", row.consent_summary
  end

  test "No cannot be combined with either Yes" do
    %i[sms_care_consent sms_marketing_consent].each do |yes|
      row = build(phone: "303-555-0142", sms_declined: true, yes => true)

      refute row.valid?, "#{yes} with a decline must be refused"
      assert_includes row.errors[:base], "Choose either Yes or No for text messages, not both"
    end
  end

  test "the phone is required only when consenting to texts" do
    %i[sms_care_consent sms_marketing_consent].each do |yes|
      row = build(yes => true)

      refute row.valid?
      assert_includes row.errors[:phone], "is required to receive text messages"
      row.phone = "(303) 555-0142"
      assert row.valid?, row.errors.full_messages.to_sentence
    end
  end

  test "both kinds of consent are recorded and summarised" do
    row = build(phone: "+1 303 555 0142", sms_care_consent: true, sms_marketing_consent: true)

    assert row.valid?
    assert_equal "Consented to customer care and marketing text messages", row.consent_summary
  end

  test "a phone number must carry 10 to 15 digits and nothing but phone characters" do
    [ "303-555-0142", "(303) 555-0142", "+1 303.555.0142", "+44 20 7946 0958" ].each do |ok|
      assert build(phone: ok).valid?, "#{ok} should be accepted"
    end
    [ "555-0142", "call me", "303-555-0142 ext nine", "1" * 16 ].each do |bad|
      refute build(phone: bad).valid?, "#{bad.inspect} should be refused"
    end
  end

  test "name, email and message are required, and the email must look like one" do
    refute build(name: "  ").valid?
    refute build(message: "").valid?
    refute build(email: "not-an-email").valid?
    refute build(message: "x" * (ContactSubmission::MESSAGE_LIMIT + 1)).valid?
  end

  test "input is tidied: email lowercased, whitespace squished" do
    row = build(name: "  Jordan   Lee ", email: " Jordan@Example.COM ", phone: " 303  555 0142 ")
    row.valid?

    assert_equal "Jordan Lee", row.name
    assert_equal "jordan@example.com", row.email
    assert_equal "303 555 0142", row.phone
  end

  test "the stored disclosure is the server's wording, whatever the caller passes" do
    row = build(disclosure_version: "forged", disclosure_text: "I agreed to nothing")
    row.save!

    assert_equal ContactSubmission::DISCLOSURE_VERSION, row.disclosure_version
    assert_equal ContactSubmission.disclosure_text, row.disclosure_text
    ContactSubmission::CONSENT_LABELS.each_value { |label| assert_includes row.disclosure_text, label }
    ContactSubmission::DISCLOSURE_PARAGRAPHS.each { |paragraph| assert_includes row.disclosure_text, paragraph }
  end

  test "the disclosure carries the carrier-required wording, verbatim" do
    text = ContactSubmission::DISCLOSURE_PARAGRAPHS

    assert_equal 3, text.size
    assert_equal "McRitchie Studio LLC (doing business as McRitchie Studio) would like your consent to send customer care and/or marketing text message communications from (303) 222-2113 to your mobile number listed above. Customer care messages may include responses to messages you send us, as well as information relevant to your relationship with us. Marketing messages may include discount codes, special deals or texts promoting our products/services.", text[0]
    assert_equal "Consent is not a condition of purchase. Message frequency varies. Message and data rates may apply. Reply 'STOP' to unsubscribe at any time. Reply 'HELP' for assistance or more information.", text[1]
    assert_equal "We do not share your mobile opt-in information with anyone. Our combined Privacy Policy and Messaging Terms and Conditions are available at https://mcritchie.studio/privacy.", text[2]
    assert_equal [
      "Yes, I consent to receive customer care messages from McRitchie Studio",
      "Yes, I consent to receive marketing text messages from McRitchie Studio",
      "No, I do not want to receive any text messages from McRitchie Studio"
    ], ContactSubmission::CONSENT_LABELS.values
  end

  test "a saved submission cannot be edited: it is a record of what happened" do
    row = build
    row.save!

    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(name: "Someone Else") }
  end

  # --- what a log may carry ---------------------------------------------------

  test "the request filter masks the form's phone and message where they are nested" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = { "contact_submission" => { "name" => "Jordan Lee", "phone" => "303-555-0142", "message" => "Hello there" } }

    filtered = filter.filter(params).fetch("contact_submission")
    assert_equal "[FILTERED]", filtered["phone"]
    assert_equal "[FILTERED]", filtered["message"]
    assert_equal "Jordan Lee", filtered["name"]
  end

  # The filter names this form's keys only. A bare :message would also mask
  # every other `message` param in the app and, through filter_attributes,
  # every model's `message` column in an inspect (ErrorLog among them).
  test "the request filter leaves another form's message alone" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    assert_equal "boom", filter.filter("message" => "boom")["message"]
    assert_equal "boom", filter.filter("error_log" => { "message" => "boom" }).dig("error_log", "message")
  end

  test "inspecting a submission shows neither the phone number nor the message" do
    row = build(phone: "303-555-0142", message: "My private note.")

    refute_includes row.inspect, "555-0142"
    refute_includes row.inspect, "My private note"
    assert_includes row.inspect, "Jordan Lee"
  end
end
