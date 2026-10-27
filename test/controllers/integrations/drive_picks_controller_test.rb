require "test_helper"
require "support/google_connect_fakes"

# [integration] drive-files-you-pick: the Picker's token and the picks it
# records. A token is minted only for the viewer's OWN drive.file connection,
# is never the refresh token, and is never cached; without the Picker key the
# endpoint says so. A pick is stored only after the hub reads the file with
# the connection's token, so a guessed id or a folder is refused. Google is a
# stand-in throughout.
class Integrations::DrivePicksControllerTest < ActionDispatch::IntegrationTest
  include GoogleConnectFakes

  setup { log_in_as users(:viewer) }
  teardown { reset_google_connect }

  def viewer = users(:viewer)
  def own_drive(scope: "openid #{DRIVE}") = store_google(email: "viewer@gmail.test", scope:, user: viewer, abilities: [ :drive ])
  def post_json(path, body) = post(path, params: body.to_json, headers: { "Content-Type" => "application/json", "Accept" => "application/json" })

  test "[integration] the token endpoint mints a short-lived token for the viewer's own connection, with the key and app id" do
    with_connect_env do
      with_picker_key do
        connection = own_drive
        google_answers(200, { access_token: "ya29.picker" })
        post_json integrations_drive_token_path, connection_id: connection.id

        assert_response :success
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal({ "access_token" => "ya29.picker", "api_key" => "test-picker-key", "app_id" => "1234567" }, response.parsed_body)
        assert_no_match(/synthetic-refresh/, response.body)
        assert_equal "refresh_token", google_requests.last[:form][:grant_type]
      end
    end
  end

  test "[integration] the Picker's app id is the project number that leads the OAuth client id" do
    with_connect_env do
      ENV["GOOGLE_CONNECT_CLIENT_ID"] = "123456789-abc.apps.googleusercontent.com"
      assert_equal "123456789", GoogleConnect::Picker.app_id
      ENV["GOOGLE_CONNECT_CLIENT_ID"] = "test-connect-id"
      assert_nil GoogleConnect::Picker.app_id, "no project number, no guess"
      with_picker_key(set: false) { refute GoogleConnect::Picker.configured? }
    end
  end

  test "[integration] another person's connection, the household's included, gets no token: 404" do
    with_connect_env do
      with_picker_key do
        household = store_google(scope: "openid #{DRIVE}", abilities: [ :drive ]) # the admin's
        google_answers(200, { access_token: "ya29.not-yours" })
        post_json integrations_drive_token_path, connection_id: household.id

        assert_response :not_found
        # The test env's 404 page quotes test source, so the proof is that Google was never asked.
        assert_empty google_requests, "no token was minted"
      end
    end
  end

  test "[integration] a legacy drive.readonly connection gets no Picker token until it reconnects" do
    with_connect_env do
      with_picker_key do
        connection = own_drive
        connection.update_columns(scope: "openid #{DRIVE_LEGACY}")
        post_json integrations_drive_token_path, connection_id: connection.id
        assert_response :not_found
      end
    end
  end

  test "[integration] without the Picker key the token endpoint says picking isn't set up" do
    with_connect_env do
      with_picker_key(set: false) do
        post_json integrations_drive_token_path, connection_id: own_drive.id
        assert_response :service_unavailable
        assert_includes response.parsed_body["error"], "Drive picking isn't set up yet"
      end
    end
  end

  test "[integration] picks are read with the connection's token before they are stored; guesses and folders are refused" do
    with_connect_env do
      connection = own_drive
      google_answers(200, { access_token: "ya29.picks" })
      google_reads("#{GoogleConnect::DriveReader::FILES_URL}/f1" => [ 200, { id: "f1", name: "Q3 plan", mimeType: "application/pdf", webViewLink: "https://drive.google.com/f1" } ],
                   "#{GoogleConnect::DriveReader::FILES_URL}/dir" => [ 200, { id: "dir", name: "Clients", mimeType: GoogleDrivePick::FOLDER_MIME } ],
                   "#{GoogleConnect::DriveReader::FILES_URL}/guess" => [ 404, { error: { message: "File not found" } } ])

      post_json integrations_drive_picks_path, connection_id: connection.id, file_ids: %w[f1 dir guess]

      assert_response :success
      assert_equal [ "Q3 plan" ], response.parsed_body["picked"]
      assert_equal 2, response.parsed_body["refused"].size
      pick = connection.drive_picks.sole
      assert_equal [ "f1", "Q3 plan", "https://drive.google.com/f1" ], [ pick.file_id, pick.name, pick.url ]
      assert_equal viewer.reload.slug, pick.picked_by
      assert(read_requests.all? { _2 == "ya29.picks" }, "read with the connection's own token")
      assert_match(/1 file shared with your agents\. Not shared: 2 items/, flash[:notice])
    end
  end

  test "[integration] picks never land on another person's connection" do
    with_connect_env do
      household = store_google(scope: "openid #{DRIVE}", abilities: [ :drive ])
      post_json integrations_drive_picks_path, connection_id: household.id, file_ids: %w[f1]
      assert_response :not_found
      assert_equal 0, GoogleDrivePick.count
    end
  end

  test "[integration] Remove forgets the viewer's own pick, and another person's pick answers 404" do
    with_connect_env do
      mine = own_drive.drive_picks.create!(file_id: "f1", name: "Q3 plan", picked_at: Time.current)
      theirs = store_google(scope: "openid #{DRIVE}", abilities: [ :drive ]).drive_picks.create!(file_id: "f2", name: "Theirs", picked_at: Time.current)

      delete integrations_drive_pick_path(theirs)
      assert_response :not_found
      delete integrations_drive_pick_path(mine)
      assert_redirected_to integrations_path
      assert_equal [ theirs.id ], GoogleDrivePick.pluck(:id)
    end
  end

  test "[integration] signed out, nothing is reachable" do
    get logout_path
    post_json integrations_drive_token_path, connection_id: 1
    assert_response :unauthorized
    assert_empty google_requests
  end
end
