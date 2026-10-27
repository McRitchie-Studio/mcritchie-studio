require "test_helper"
require "support/google_connect_fakes"

# [integration] /admin/google: Connect per ability sends the admin to Google
# for that ability's scope, the callback stores it (refusing a grant without
# it) and comes back where Connect was pressed, the standing page proves each
# ability with its read, and Disconnect drops one ability or, with the last,
# revokes and deletes. Google is a stand-in throughout.
class Admin::GoogleControllerTest < ActionDispatch::IntegrationTest
  include GoogleConnectFakes

  setup { log_in_as users(:alex) }
  teardown { reset_google_connect }

  # Starts a connect; returns Google's authorize query (state, scope, ...).
  def begin_connect(ability = "calendar", return_to: nil)
    get admin_google_connect_path(ability:, return_to:)
    assert_response :redirect
    Rack::Utils.parse_query(URI(response.location).query)
  end

  # Connects `ability` all the way: Google grants `scope`.
  def connect!(ability, scope:, return_to: nil)
    state = begin_connect(ability, return_to:)["state"]
    google_answers(200, token_grant(scope:))
    get admin_google_callback_path(code: "c0de", state:)
  end

  def reads_answer_everything
    google_answers(200, { access_token: "ya29.page" })
    google_reads(
      GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: [ { id: "e1", summary: "Lender call", start: { dateTime: 1.day.from_now.iso8601 }, end: { dateTime: (1.day.from_now + 1.hour).iso8601 } } ] } ],
      "#{GoogleConnect::GmailReader::MESSAGES_URL}/" => [ 200, { id: "m1", payload: { headers: [ { name: "Subject", value: "Term sheet" } ] } } ],
      GoogleConnect::GmailReader::MESSAGES_URL => [ 200, { resultSizeEstimate: 9, messages: [ { id: "m1" } ] } ],
      "#{GoogleConnect::DriveReader::FILES_URL}/f1" => [ 200, { id: "f1", name: "Q3 plan", mimeType: "x", modifiedTime: 1.hour.ago.iso8601 } ],
      GoogleConnect::DriveReader::FILES_URL => [ 200, { files: [ { id: "f9", name: "Whole-Drive file", mimeType: "x", modifiedTime: 1.hour.ago.iso8601 } ] } ]
    )
  end

  test "[integration] every action is admin only" do
    get logout_path
    get admin_google_connect_path(ability: "calendar")
    assert_response :redirect
    assert_no_match(/accounts\.google\.com/, response.location)
    get admin_google_path
    assert_response :redirect
    delete admin_google_disconnect_path(ability: "calendar")
    assert_response :redirect
  end

  test "[integration] the old standing page redirects to /admin/google, and the callback keeps its registered path" do
    get "/admin/google_calendar"
    assert_redirected_to "/admin/google"
    assert_equal "/admin/google_calendar/callback", admin_google_callback_path
  end

  test "[integration] connect per ability requests its scope and returns to integrations" do
    with_connect_env do
      { "calendar" => CALENDAR, "gmail" => GMAIL, "drive" => DRIVE }.each do |ability, scope|
        query = begin_connect(ability, return_to: "/integrations")

        assert_match %r{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?}, response.location
        assert_equal [ "openid", "email", scope ], query["scope"].split, ability
        assert_equal "true", query["include_granted_scopes"]
        assert_equal admin_google_callback_url, query["redirect_uri"]

        google_answers(200, token_grant(scope: "openid email #{scope}"))
        get admin_google_callback_path(code: "c0de", state: query["state"])
        assert_redirected_to "/integrations", ability
        assert_equal "#{GoogleConnection::ABILITY_NAMES.fetch(ability.to_sym)} connected for alex@mcritchie.studio.", flash[:notice]
      end
      assert_equal %i[calendar gmail drive], GoogleConnection.sole.abilities, "each connect kept the others"
    end
  end

  test "[integration] connecting Drive after Calendar keeps Calendar (incremental consent)" do
    with_connect_env do
      connect!("calendar", scope: SCOPE)
      connect!("drive", scope: "openid email #{DRIVE}") # Google answers only the new scope here; the row keeps both

      assert_equal %i[calendar drive], GoogleConnection.sole.abilities
    end
  end

  test "[integration] connect all requests identity and the three read scopes in one sign-in" do
    with_connect_env do
      query = begin_connect("all", return_to: "/integrations")

      assert_match %r{\Ahttps://accounts\.google\.com/o/oauth2/v2/auth\?}, response.location
      assert_equal [ "openid", "email", CALENDAR, GMAIL, DRIVE ], query["scope"].split
      assert_equal "true", query["include_granted_scopes"]

      google_answers(200, token_grant(scope: "openid email #{CALENDAR} #{GMAIL} #{DRIVE}"))
      get admin_google_callback_path(code: "c0de", state: query["state"])

      assert_redirected_to "/integrations"
      assert_equal "Google Calendar, Gmail, and Google Drive connected for alex@mcritchie.studio.", flash[:notice]
      assert_equal %i[calendar gmail drive], GoogleConnection.sole.abilities
    end
  end

  test "[integration] a partial grant on connect all stores the granted subset and names the unticked one" do
    with_connect_env do
      connect!("all", scope: "openid email #{CALENDAR} #{DRIVE}", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_nil flash[:alert], "a partial grant is not a refusal"
      assert_equal "Google Calendar and Google Drive connected for alex@mcritchie.studio. Gmail was left unticked, so it stays off.", flash[:notice]
      assert_equal %i[calendar drive], GoogleConnection.sole.abilities
    end
  end

  test "[integration] connect all with every permission unticked stores nothing" do
    with_connect_env do
      connect!("all", scope: "openid email")

      assert_redirected_to admin_google_path
      assert_match(/granted none of Google Calendar, Gmail or Google Drive/, flash[:alert])
      assert_equal 0, GoogleConnection.count
    end
  end

  test "[integration] a Gmail disconnected here stays off when Drive connects and Google echoes Gmail" do
    with_connect_env do
      connect!("all", scope: "openid email #{CALENDAR} #{GMAIL}")
      delete admin_google_disconnect_path(ability: "gmail")
      assert_equal [ :calendar ], GoogleConnection.sole.abilities # the control: Gmail is off here

      connect!("drive", scope: "openid email #{CALENDAR} #{GMAIL} #{DRIVE}") # include_granted_scopes echoes Gmail

      assert_equal "Google Drive connected for alex@mcritchie.studio.", flash[:notice]
      assert_equal %i[calendar drive], GoogleConnection.sole.abilities
    end
  end

  test "[integration] the standing page offers Connect Google, Connect the rest, then the account" do
    with_connect_env do
      get admin_google_path
      assert_select "[data-test='google-connect-all'][data-state='none'] a[data-test='google-connect-all-button'][href='#{admin_google_connect_path(ability: 'all')}']", text: "Connect Google"

      store_google(scope: "openid #{CALENDAR}")
      reads_answer_everything
      get admin_google_path
      assert_select "[data-test='google-connect-all'][data-state='some'] [data-test='google-connect-all-button']", text: "Connect the rest"
      assert_select "[data-test='google-connect-all-status']", text: /Google Calendar connected\. Add Gmail and Google Drive/

      store_google(scope: "openid #{CALENDAR} #{GMAIL} #{DRIVE}")
      get admin_google_path
      assert_select "[data-test='google-connect-all'][data-state='all'] [data-test='google-connect-all-status']", text: "Google connected as alex@mcritchie.studio"
      assert_select "[data-test='google-connect-all-button']", 0
    end
  end

  test "[integration] the standing page offers no Connect Google without the OAuth client" do
    with_connect_env(creds: false) do
      get admin_google_path
      assert_select "[data-test='google-connect-all']", 0
    end
  end

  test "[integration] a grant without the requested scope is refused and nothing is stored" do
    with_connect_env do
      connect!("gmail", scope: "openid email")

      assert_redirected_to admin_google_path
      assert_match(/did not grant Gmail/, flash[:alert])
      assert_equal 0, GoogleConnection.count
    end
  end

  test "[integration] an unknown ability is refused before Google is asked" do
    with_connect_env do
      get admin_google_connect_path(ability: "contacts", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_equal Admin::GoogleController::UNKNOWN_ABILITY, flash[:alert]
    end
  end

  test "[integration] connect without the OAuth client says so and asks Google nothing" do
    with_connect_env(creds: false) do
      get admin_google_connect_path(ability: "gmail")

      assert_redirected_to admin_google_path
      assert_match(/GOOGLE_CONNECT_CLIENT_ID and GOOGLE_CONNECT_CLIENT_SECRET are not set/, flash[:alert])
    end
  end

  test "[integration] the standing page proves each connected ability with its read, and shows no token" do
    with_connect_env do
      connection = store_google(scope: "openid #{CALENDAR} #{GMAIL} #{DRIVE}")
      connection.drive_picks.create!(file_id: "f1", name: "Q3 plan", picked_at: Time.current)
      reads_answer_everything
      get admin_google_path

      assert_response :success
      %w[calendar gmail drive].each { assert_select "[data-test='google-section'][data-ability='#{_1}'][data-state='connected']" }
      assert_select "[data-ability='calendar'] [data-test='google-read-item']", text: /Lender call/
      assert_select "[data-ability='gmail'] [data-test='google-read-item']", text: /Term sheet/
      assert_select "[data-ability='drive'] [data-test='google-read-item']", text: /Q3 plan/
      assert_select "[data-ability='drive'] [data-test='google-read-item']", text: /Whole-Drive file/, count: 0
      assert_select "[data-test='drive-read-kind'][data-kind='picked']"
      assert_select "[data-test='google-disconnect']", 3
      assert_select "[data-test='google-connect']", 0
      assert_select "[data-test='google-server']", 0, "nothing is missing, so no setup shows"
      assert_no_match(/synthetic-refresh|ya29\./, response.body)
    end
  end

  test "[integration] a disabled API shows Google's error plainly in that ability's section only" do
    with_connect_env do
      store_google(scope: "openid #{CALENDAR} #{GMAIL}")
      reads_answer_everything
      google_reads(GoogleConnect::GmailReader::MESSAGES_URL => [ 403, { error: { message: "Gmail API has not been used in project 1 before or it is disabled." } } ],
                   GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: [] } ])
      get admin_google_path

      assert_select "[data-ability='gmail'][data-state='read_failed'] [data-test='google-read-error']", /Gmail answered 403: Gmail API has not been used/
      assert_select "[data-ability='calendar'][data-state='connected']"
      assert_select "[data-ability='drive'][data-state='none'] [data-test='google-connect']"
    end
  end

  test "[integration] a revoked connection says disconnect and connect again" do
    with_connect_env do
      store_google
      google_answers(400, { error: "invalid_grant" })
      get admin_google_path

      assert_select "[data-ability='calendar'][data-state='read_failed'] [data-test='google-read-error']", /revoked or went unused/
    end
  end

  # [component] drive-files-you-pick: a legacy drive.readonly row still reads the
  # whole Drive's newest and is labelled so; a drive.file row without the Picker
  # key says by NAME what to set.
  test "[integration] the Drive section reads a legacy row's whole Drive, and names the missing Picker key" do
    with_connect_env do
      store_google(scope: "openid #{DRIVE_LEGACY}").update_columns(scope: "openid #{DRIVE_LEGACY}")
      reads_answer_everything
      get admin_google_path
      assert_select "[data-ability='drive'] [data-test='drive-read-kind'][data-kind='legacy']", /reconnect to choose files/
      assert_select "[data-ability='drive'] [data-test='google-read-item']", text: /Whole-Drive file/

      GoogleConnection.update_all(scope: "openid #{DRIVE}")
      with_picker_key(set: false) { get admin_google_path }
      assert_select "[data-ability='drive'] [data-test='drive-picker-unset']", /GOOGLE_PICKER_API_KEY/
    end
  end

  test "[integration] the standing page names the missing OAuth client and offers no Connect" do
    with_connect_env(creds: false) do
      get admin_google_path
      assert_select "[data-test='google-server'] [data-field='client'][data-set='false']", /GOOGLE_CONNECT_CLIENT_ID/
      assert_select "[data-test='google-server'] [data-field='encryption']", 0, "encryption is ready, so it is not shown"
      assert_select "[data-test='google-connect']", 0
    end
  end

  test "[integration] disconnecting one of several abilities keeps the token and asks Google nothing" do
    with_connect_env do
      store_google(scope: "openid #{CALENDAR} #{DRIVE}")
      google_answers(200, {})
      delete admin_google_disconnect_path(ability: "drive", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_equal [ :calendar ], GoogleConnection.sole.abilities
      assert_empty google_requests, "no revoke: it would end Calendar too"
      assert_equal "Google Drive disconnected here. The account's other Google connections stay.", flash[:notice]
    end
  end

  test "[integration] disconnecting the last ability revokes at Google and deletes the row" do
    with_connect_env do
      store_google
      google_answers(200, {})
      delete admin_google_disconnect_path(ability: "calendar", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_response :see_other
      assert_equal 0, GoogleConnection.count
      assert_equal GoogleConnect::OAuthClient::REVOKE_URL, google_requests.last[:url]
      assert_equal "Google Calendar disconnected: deleted here and revoked at Google.", flash[:notice]
    end
  end

  test "[integration] disconnect survives a TLS error from Google's revoke endpoint" do
    with_connect_env do
      store_google
      GoogleConnect::OAuthClient.http = ->(_method, _url, _form) { raise OpenSSL::SSL::SSLError, "certificate verify failed" }
      delete admin_google_disconnect_path(ability: "calendar", return_to: "/integrations")

      assert_redirected_to "/integrations"
      assert_equal 0, GoogleConnection.count
      assert_match(/Google did not confirm the revoke/, flash[:notice])
    end
  end

  test "[integration] a return_to off the allow-list is ignored: never an open redirect" do
    with_connect_env do
      [ "https://evil.example/integrations", "//evil.example", "/integrations/../admin", "/integrations?x=1", "/admin/google/connect" ].each do |target|
        connect!("calendar", scope: SCOPE, return_to: target)
        assert_redirected_to admin_google_path, target

        delete admin_google_disconnect_path(ability: "calendar", return_to: target)
        assert_redirected_to admin_google_path, target
      end
    end
  end

  test "[integration] a state mismatch is refused before any exchange" do
    with_connect_env do
      begin_connect
      google_answers
      get admin_google_callback_path(code: "c0de", state: "forged")

      assert_response :bad_request
      assert_empty google_requests
      assert_equal 0, GoogleConnection.count
    end
  end

  test "[integration] a callback with no connect in the session is refused, even with a blank state" do
    with_connect_env do
      google_answers
      get admin_google_callback_path(code: "c0de", state: "")
      assert_response :bad_request
      assert_empty google_requests
    end
  end

  test "[integration] a declined sign-in connects nothing and comes back where it started" do
    with_connect_env do
      state = begin_connect("drive", return_to: "/integrations")["state"]
      get admin_google_callback_path(error: "access_denied", state:)

      assert_redirected_to "/integrations"
      assert_match(/declined/, flash[:alert])
      assert_equal 0, GoogleConnection.count
    end
  end

  test "[integration] the auth code is filtered from the callback's logged parameters" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    logged = filter.filter("controller" => "admin/google", "action" => "callback", "code" => "synthetic-code", "state" => "s1")

    assert_equal "[FILTERED]", logged["code"]
    assert_equal "s1", logged["state"]
  end
  test "[component] the standing page says agents read each household connection" do
    store_google(scope: "openid #{CALENDAR}")
    reads_answer_everything
    with_connect_env { get admin_google_path }

    line = css_select("[data-test='google-section'][data-ability='calendar'] [data-test='google-who-reads']").first
    assert_equal "Your agents can read this", line.text.squish
    assert_empty css_select("[data-test='google-section'][data-ability='drive'] [data-test='google-who-reads']")
  end
end
