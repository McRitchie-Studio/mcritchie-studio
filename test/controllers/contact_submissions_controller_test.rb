require "test_helper"

# /contact — the public contact form and SMS opt-in page.
#
#   [component]    what the page renders: the fields, three unticked consent
#                  boxes in the fixed wording, the disclosure under the form.
#   [integration]  what a POST does: the consent proof stored, Alex emailed,
#                  the consent rules held server-side, bots turned away.
class ContactSubmissionsControllerTest < ActionDispatch::IntegrationTest
  VALID = { name: "Jordan Lee", email: "jordan@example.com", message: "I would like a quote." }.freeze
  PROOF = ContactSubmissionsController::PROOF_FIELD

  # What the page's script writes: the signed render time, reversed.
  def browser_proof(rendered_at = 10.seconds.ago)
    ContactSubmissionsController.proof_for(rendered_at).reverse
  end

  # A person's submission by default: the page's proof, written long enough ago.
  def submit(**fields)
    fields = { PROOF => browser_proof }.merge(fields)
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
        submit(ContactSubmissionsController::HONEYPOT_FIELD => "https://spam.example")
      end
    end

    assert_redirected_to contact_form_path
    follow_redirect!
    assert_select "[data-test='contact-sent']"
    assert_select "[data-test='contact-sent-sms']", count: 0
  end

  # --- [integration] the browser proof ---------------------------------------

  test "[component] the page carries a signed render time and the script that writes it" do
    get contact_form_path

    input = css_select("form[data-test='contact-form'] input[type='hidden'][data-test='contact-proof']").first
    assert input, "the proof field is inside the form"
    assert_equal "contact_submission[#{PROOF}]", input["name"]
    assert_nil input["value"], "the server never writes the proof into the field itself"
    rendered_at = ContactSubmissionsController.verifier.verified(input["data-proof"], purpose: :contact_form)
    assert_in_delta Time.current.to_f, rendered_at, 5
    assert_equal "$el.value = $el.dataset.proof.split('').reverse().join('')", input["x-init"]
  end

  # The RobertniB bot posts the HTML back without running the page's script.
  test "[integration] a post without the browser proof is kept flagged and Alex is not emailed" do
    assert_difference -> { ContactSubmission.count } => 1, -> { Studio::EmailDelivery.count } => 0 do
      submit(PROOF => "")
    end

    assert_equal "no_browser_proof", ContactSubmission.recent.first.spam_reason
    assert_redirected_to contact_form_path
    follow_redirect!
    assert_select "[data-test='contact-sent']", text: /your message is on its way/
  end

  test "[integration] the token copied unreversed, forged, or expired is no proof" do
    stale = browser_proof
    [ContactSubmissionsController.proof_for(10.seconds.ago), "not-a-token", "x--y".reverse].each do |written|
      assert_no_difference -> { Studio::EmailDelivery.count } do
        submit(PROOF => written)
      end
      assert_equal "no_browser_proof", ContactSubmission.recent.first.spam_reason, written
    end

    travel ContactSubmissionsController::PROOF_TTL + 1.minute do
      assert_no_difference -> { Studio::EmailDelivery.count } do
        submit(PROOF => stale)
      end
      assert_equal "no_browser_proof", ContactSubmission.recent.first.spam_reason, "an expired proof"
    end
  end

  test "[integration] a post sooner than a person can type is kept flagged and not emailed" do
    assert_difference -> { ContactSubmission.count } => 1, -> { Studio::EmailDelivery.count } => 0 do
      submit(PROOF => browser_proof(1.second.ago))
    end

    assert_equal "too_fast", ContactSubmission.recent.first.spam_reason
  end

  test "[integration] a post just past the minimum fill time reaches Alex unflagged" do
    rendered_at = (ContactSubmissionsController::MIN_FILL_SECONDS + 0.5).seconds.ago
    assert_difference -> { Studio::EmailDelivery.count }, 1 do
      submit(PROOF => browser_proof(rendered_at))
    end

    refute ContactSubmission.recent.first.flagged?
  end

  # A visitor who fixes one box and resubmits in a second has still spent their
  # time on the form, so the re-rendered proof keeps the first render time.
  test "[integration] a refused submission re-renders a proof that keeps the first render time" do
    submit(sms_care_consent: "1", PROOF => browser_proof(20.seconds.ago))

    assert_response :unprocessable_entity
    input = css_select("input[data-test='contact-proof'][data-proof]").sole
    rendered_at = ContactSubmissionsController.verifier.verified(input["data-proof"], purpose: :contact_form)
    assert_in_delta 20.seconds.ago.to_f, rendered_at, 5
  end

  # The honeypot used to be `company_url`. A browser's address autofill matches
  # "company" and ignores autocomplete="off", so a real visitor could have the
  # trap filled for them: they saw the thank-you and nothing was stored or
  # sent. A value under the old name must now be an ordinary, stored submission.
  test "[integration] a value under the old honeypot name no longer drops a real visitor" do
    assert_difference -> { ContactSubmission.count } => 1, -> { Studio::EmailDelivery.count } => 1 do
      submit(company_url: "https://acme.example", phone: "303-555-0142", sms_care_consent: "1")
    end

    assert ContactSubmission.recent.first.sms_care_consent, "the SMS consent record was kept"
  end

  # Words a browser or password manager matches in a field's name, id or label
  # to decide what to autofill. The honeypot may contain none of them.
  AUTOFILL_TOKENS = %w[
    name email mail tel phone mobile fax url website web site homepage company organization organisation
    business employer title job address addr street city town state province region zip postal postcode
    country user login account pass card credit cvc cvv expir birth bday dob age sex gender
    language nickname first last middle given family additional honorific search contact subject
  ].freeze

  test "[integration] the honeypot's name, id and label match no autofill token" do
    field = ContactSubmissionsController::HONEYPOT_FIELD.to_s
    get contact_form_path
    input = css_select("input[data-test='contact-honeypot']").first
    label = css_select("label[for='#{input['id']}']").first

    assert_equal "contact_submission[#{field}]", input["name"]
    # The form's scope is shared by every field; what is checked is the part
    # that names this one.
    seen = { "field name" => field, "id" => input["id"].delete_prefix("contact_submission_"), "label" => label.text }
    seen.each do |what, value|
      squashed = value.downcase.gsub(/[^a-z]/, "")
      hits = AUTOFILL_TOKENS.select { |token| squashed.include?(token) }
      assert_empty hits, "the honeypot #{what} #{value.inspect} matches autofill token(s) #{hits.inspect}"
    end
    assert_includes AUTOFILL_TOKENS, "company", "the list still catches the name this field used to have"
    assert_includes AUTOFILL_TOKENS, "url"
  end

  test "[component] the honeypot is off-screen, out of the tab order and hidden from assistive tech" do
    get contact_form_path

    assert_select "form[data-test='contact-form'] input[data-test='contact-honeypot']", count: 1
    assert_select "input[name='contact_submission[company_url]']", count: 0
    assert_select "div[aria-hidden='true'][style*='left:-9999px'] input[data-test='contact-honeypot']" \
                  "[type='text'][tabindex='-1'][autocomplete='off']", count: 1
    assert_select "input[data-test='contact-honeypot'][value]", count: 0
    assert_select "input[data-test='contact-honeypot'][required]", count: 0
  end

  # --- [integration] the request log -----------------------------------------

  # What the "Parameters:" line of a request log carries. Read off the real log
  # subscriber, so a filter that is configured but does not match fails here.
  def logged_lines
    io = StringIO.new
    original = ActionController::Base.logger
    ActionController::Base.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    ActionController::Base.logger = original
  end

  test "[integration] the request log carries neither the phone number nor the message" do
    log = logged_lines do
      submit(phone: "(303) 555-0142", message: "My private note to the studio.", sms_care_consent: "1")
    end

    assert_match(/Processing by ContactSubmissionsController#create/, log, "the request was logged")
    assert_match(/Parameters: .*"phone" ?=> ?"\[FILTERED\]"/, log)
    assert_match(/Parameters: .*"message" ?=> ?"\[FILTERED\]"/, log)
    refute_includes log, "555-0142"
    refute_includes log, "My private note"
    refute_includes log, "jordan@example.com"
    assert_match(/"name" ?=> ?"Jordan Lee"/, log, "an unfiltered field is still logged: the capture is live")
  end

  test "[integration] a refused submission is logged without them too" do
    log = logged_lines { submit(phone: "303-555-0142", message: "My private note.", sms_care_consent: "1", sms_declined: "1") }

    assert_response :unprocessable_entity
    refute_includes log, "555-0142"
    refute_includes log, "My private note"
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
