require "test_helper"
require "support/google_connect_fakes"

# [component] drive-files-you-pick: the Google Drive card on /integrations.
# A drive.file connection lists its picked files and offers Pick files (its URLs
# in data attributes, no key or token in the HTML), or says picking isn't set up
# when the server has no Picker key; it says a folder must be shared instead. A
# legacy drive.readonly connection offers no Picker, only the reconnect hint.
class IntegrationsDriveCardTest < ActionDispatch::IntegrationTest
  include GoogleConnectFakes

  setup { log_in_as users(:viewer) }
  teardown { reset_google_connect }

  CARD = "[data-test='google-connection'][data-ability='drive']".freeze

  def own_drive = store_google(email: "viewer@gmail.test", scope: "openid #{DRIVE}", user: users(:viewer), abilities: [ :drive ])

  test "[component] a drive.file connection offers Pick files and lists its picks, with no key or token in the page" do
    with_connect_env do
      with_picker_key do
        connection = own_drive
        connection.drive_picks.create!(file_id: "f1", name: "Q3 plan", url: "https://docs.google.com/d/f1", picked_at: Time.current)
        get integrations_path

        assert_select "#{CARD} [data-test='drive-picks'][data-mode='picked']"
        assert_select "#{CARD} [data-test='drive-pick'][data-file-id='f1'] a[href='https://docs.google.com/d/f1']", text: "Q3 plan"
        assert_select "#{CARD} [data-test='drive-unpick']"
        assert_select "#{CARD} button[data-test='drive-pick-files'][data-drive-picker][data-connection-id='#{connection.id}']" do |button|
          assert_equal integrations_drive_token_path, button.first["data-token-url"]
          assert_equal "https://apis.google.com/js/api.js", button.first["data-loader-url"]
        end
        assert_select "#{CARD} [data-test='drive-folder-hint']", text: /share it with your agent's email address/
        assert_select "#{CARD} [data-test='drive-legacy']", 0
        refute_includes response.body, "test-picker-key", "the key comes from the token endpoint only"
        assert_no_match(/synthetic-refresh|ya29\./, response.body)
      end
    end
  end

  test "[component] without the Picker key the card says Drive picking isn't set up yet" do
    with_connect_env do
      with_picker_key(set: false) do
        own_drive
        get integrations_path

        assert_select "#{CARD} [data-test='drive-picker-unset']", text: /Drive picking isn't set up yet\./
        assert_select "#{CARD} [data-test='drive-pick-files']", 0
        assert_select "#{CARD} [data-test='drive-pick-count']", text: /No files shared/
      end
    end
  end

  test "[component] a legacy drive.readonly connection shows the reconnect hint and no Picker" do
    with_connect_env do
      with_picker_key do
        own_drive.update_columns(scope: "openid #{DRIVE_LEGACY}")
        get integrations_path

        assert_select "#{CARD}[data-state='connected'] [data-test='drive-picks'][data-mode='legacy']"
        assert_select "#{CARD} [data-test='drive-legacy']", text: /reads every file in your Drive/
        assert_select "#{CARD} a[data-test='drive-reconnect'][href=?]", integrations_google_connect_path(ability: :drive, return_to: integrations_path)
        assert_select "#{CARD} [data-test='drive-pick-files']", 0
      end
    end
  end
end
