require "test_helper"

# /contact — the public contact form and SMS opt-in page.
#
#   [component]    what the page renders: the fields, three unticked consent
#                  boxes in the fixed wording, the disclosure under the form.
#   [integration]  what a POST does: the consent proof stored, Alex emailed,
#                  the consent rules held server-side, bots turned away.
class ContactSubmissionsControllerTest < ActionDispatch::IntegrationTest
  VALID = { name: "Jordan Lee", email: "jordan@example.com", message: "I would like a quote." }.freeze

  def submit(**fields)
    post contact_form_path, params: { contact_submission: VALID.merge(fields) },
                       headers: { "User-Agent" => "ContactTest/1.0" }
  end

  # /contact sits one letter from the admin mailing list's /contacts/:id. Named
  # `contact`, this route took over `contact_path` and every admin detail link
  # became "/contact.23" (caught by CI on this task's first push).
  test "[integration] the form's route does not take the mailing list's contact_path" do
    assert_equal "/contact", contact_form_path
    assert_equal "/contacts/23", contact_path(23)
  end

  # --- [component] the page --------------------------------------------------

  test "[component] anyone can open the form without signing in" do
    get contact_form_path

    assert_response :success
    assert_select "form[data-test='contact-form'][action='/contact'][method='post']" do
      assert_select "input[name='contact_submission[name]'][required]"
      assert_select "input[type='email'][name='contact_submission[email]'][required]"
      assert_select "input[type='tel'][name='contact_submission[phone]']"
      assert_select "input[type='tel'][name='contact_submission[phone]'][required]", count: 0
      assert_select "textarea[name='contact_submission[message]'][required]"
    end
  end

  test "[component] the three consent boxes carry the exact wording and none is ticked" do
    get contact_form_path

    assert_select "[data-test='contact-consent'] input[type='checkbox']", count: 3
    assert_select "[data-test='contact-consent'] input[type='checkbox'][checked]", count: 0
    labels = css_select("[data-test='contact-consent'] label span").map { |span| span.text.strip }
    assert_equal [
      "Yes, I consent to receive customer care messages from McRitchie Studio",
      "Yes, I consent to receive marketing text messages from McRitchie Studio",
      "No, I do not want to receive any text messages from McRitchie Studio"
    ], labels
  end

  test "[component] the disclosure sits directly below the form, verbatim, linking the policy" do
    get contact_form_path

    paragraphs = css_select("[data-test='sms-disclosure'] p").map(&:text)
    assert_equal ContactSubmission::DISCLOSURE_PARAGRAPHS, paragraphs
    assert_select "[data-test='sms-disclosure'] a[href='/privacy']", text: "https://mcritchie.studio/privacy"
    assert_select "form[data-test='contact-form'] + [data-test='sms-disclosure']", count: 1
    assert_select "form [data-test='sms-disclosure']", count: 0
  end

  test "[component] the confirmation shows only after a submission" do
    get contact_form_path
    assert_select "[data-test='contact-sent']", count: 0

    submit
    follow_redirect!
    assert_select "[data-test='contact-sent']", text: /your message is on its way/
    assert_select "[data-test='contact-sent-sms']", count: 0
  end

  test "[component] a consenting visitor is reminded of the program terms; a decliner is not" do
    submit(phone: "303-555-0142", sms_care_consent: "1")
    follow_redirect!
    assert_select "[data-test='contact-sent-sms']",
      text: "You are signed up for text messages from (303) 222-2113. Msg frequency varies. Msg & data rates may apply. Reply HELP for help. Reply STOP to cancel."

    submit(sms_declined: "1")
    follow_redirect!
    assert_select "[data-test='contact-sent']"
    assert_select "[data-test='contact-sent-sms']", count: 0
  end

  test "[component] a refused submission re-renders with the errors and the visitor's input" do
    submit(sms_care_consent: "1", email: "nope")

    assert_response :unprocessable_entity
    assert_select "[data-test='contact-errors'] li", text: "Phone is required to receive text messages"
    assert_select "[data-test='contact-errors'] li", text: /Email doesn't look like an email address/
    assert_select "input[name='contact_submission[name]'][value='Jordan Lee']"
    assert_select "input[type='checkbox'][name='contact_submission[sms_care_consent]'][checked]"
  end

  # --- [integration] the write -----------------------------------------------

  test "[integration] a consenting submission stores the proof and emails Alex" do
    assert_difference -> { ContactSubmission.count }, 1 do
      assert_emails 1 do
        perform_enqueued_jobs do
          submit(phone: "(303) 555-0142", sms_care_consent: "1", sms_marketing_consent: "1", sms_declined: "0")
        end
      end
    end
    assert_redirected_to contact_form_path

    row = ContactSubmission.recent.first
    assert_equal "Jordan Lee", row.name
    assert_equal "jordan@example.com", row.email
    assert_equal "(303) 555-0142", row.phone
    assert_equal "I would like a quote.", row.message
    assert row.sms_care_consent
    assert row.sms_marketing_consent
    refute row.sms_declined
    assert_equal ContactSubmission::DISCLOSURE_VERSION, row.disclosure_version
    assert_equal ContactSubmission.disclosure_text, row.disclosure_text
    assert_equal "127.0.0.1", row.ip_address
    assert_equal "ContactTest/1.0", row.user_agent
    assert_in_delta Time.current, row.created_at, 5.seconds

    outbox = Studio::EmailDelivery.recent.first
    assert_equal "ContactMailer#submission", outbox.email_key
    assert_equal "alex@mcritchie.studio", outbox.to
    assert outbox.sent?, "the outbox row was delivered"

    mail = ActionMailer::Base.deliveries.last
    assert_equal ["alex@mcritchie.studio"], mail.to
    assert_equal ["jordan@example.com"], mail.reply_to
    assert_equal "Contact form: Jordan Lee", mail.subject
  end

  test "[integration] a visitor can decline every text and still submit, with no phone" do
    assert_difference -> { ContactSubmission.count }, 1 do
      submit(sms_declined: "1")
    end

    row = ContactSubmission.recent.first
    assert row.sms_declined
    refute row.sms_consent?
    assert_nil row.phone
  end

  test "[integration] leaving every box alone submits and records no consent" do
    assert_difference -> { ContactSubmission.count }, 1 do
      submit(sms_care_consent: "0", sms_marketing_consent: "0", sms_declined: "0")
    end

    row = ContactSubmission.recent.first
    refute row.sms_consent?
    refute row.sms_declined
  end

  test "[integration] No together with Yes is refused server-side and nothing is stored or sent" do
    assert_no_difference -> { ContactSubmission.count } do
      assert_no_difference -> { Studio::EmailDelivery.count } do
        submit(phone: "303-555-0142", sms_marketing_consent: "1", sms_declined: "1")
      end
    end

    assert_response :unprocessable_entity
    assert_select "[data-test='contact-errors'] li", text: "Choose either Yes or No for text messages, not both"
  end

  test "[integration] consent without a phone number is refused" do
    assert_no_difference -> { ContactSubmission.count } do
      submit(sms_care_consent: "1")
    end

    assert_response :unprocessable_entity
  end

  test "[integration] the form cannot write the proof columns" do
    post contact_form_path, params: { contact_submission: VALID.merge(
      disclosure_version: "forged", disclosure_text: "nothing", ip_address: "9.9.9.9", user_agent: "forged"
    ) }

    row = ContactSubmission.recent.first
    assert_equal ContactSubmission::DISCLOSURE_VERSION, row.disclosure_version
    assert_equal ContactSubmission.disclosure_text, row.disclosure_text
    assert_equal "127.0.0.1", row.ip_address
    refute_equal "forged", row.user_agent
  end

  test "[integration] a filled honeypot looks like success but stores and sends nothing" do
    assert_no_difference -> { ContactSubmission.count } do
      assert_no_difference -> { Studio::EmailDelivery.count } do
        submit(company_url: "https://spam.example")
      end
    end

    assert_redirected_to contact_form_path
    follow_redirect!
    assert_select "[data-test='contact-sent']"
    assert_select "[data-test='contact-sent-sms']", count: 0
  end

  test "[integration] a mail outage is logged and the stored submission still confirms" do
    Studio::Email.stub(:deliver, ->(*, **) { raise IOError, "outbox is down" }) do
      assert_difference -> { ContactSubmission.count } => 1, -> { ErrorLog.count } => 1 do
        submit
      end
    end

    assert_redirected_to contact_form_path
  end

  # The test env caches to a null store, which never counts. Counting on the
  # store the limiter captured exercises the real wiring: the limit, the action
  # it guards, and the redirect.
  test "[integration] the sixth post in a minute is turned away, and GET is not limited" do
    hits = 0
    counting = ->(*, **) { hits += 1 }

    ContactSubmissionsController.cache_store.stub(:increment, counting) do
      assert_difference -> { ContactSubmission.count }, 5 do
        5.times { submit }
      end
      assert_no_difference -> { ContactSubmission.count } do
        submit
      end
      assert_redirected_to contact_form_path
      assert_equal "Too many messages. Try again in a minute.", flash[:alert]

      get contact_form_path
      assert_response :success
    end
    assert_equal 6, hits, "only the six POSTs were counted"
  end
end
