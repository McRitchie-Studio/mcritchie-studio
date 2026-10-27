require "application_system_test_case"
require "support/google_connect_fakes"

# [system] drive-files-you-pick: the Drive card's Pick files fetches a token from
# the hub, opens the Google Picker (stubbed here: window.google.picker defined
# before the click, so Google's loader is never fetched), and a pick is recorded
# after the hub reads the file, then listed on the card. System tests sign in as
# the admin, whose own connection this is.
class DrivePickerTest < ApplicationSystemTestCase
  include GoogleConnectFakes

  CARD = "[data-test='google-connection'][data-ability='drive']".freeze

  # A stand-in Picker: build().setVisible(true) adds a host element carrying what
  # the builder was given, and keeps the callback for the test to answer.
  STUB = <<~JS.freeze
    window.gapi = { load: (_name, opts) => opts.callback() };
    const given = {};
    function Builder() {}
    ["addView", "enableFeature", "setOAuthToken", "setDeveloperKey", "setAppId"].forEach((name) => {
      Builder.prototype[name] = function (value) { given[name] = given[name] ? [].concat(given[name], value) : value; return this; };
    });
    Builder.prototype.setCallback = function (cb) { window.__pickerCallback = cb; return this; };
    Builder.prototype.build = function () {
      return { setVisible() {
        const host = document.createElement("div");
        host.dataset.test = "drive-picker-host";
        host.dataset.token = given.setOAuthToken;
        host.dataset.key = given.setDeveloperKey;
        host.dataset.appId = given.setAppId;
        host.dataset.features = [].concat(given.enableFeature).join(",");
        host.dataset.folders = given.addView.selectFolder;
        document.body.appendChild(host);
      } };
    };
    function DocsView() {}
    DocsView.prototype.setIncludeFolders = function () { return this; };
    DocsView.prototype.setSelectFolderEnabled = function (on) { this.selectFolder = String(on); return this; };
    window.google = { picker: { PickerBuilder: Builder, DocsView, ViewId: { DOCS: "all" },
      Feature: { MULTISELECT_ENABLED: "multi", SUPPORT_DRIVES: "drives" },
      Response: { ACTION: "action", DOCUMENTS: "docs" }, Action: { PICKED: "picked", CANCEL: "cancel" }, Document: { ID: "id" } } };
  JS

  test "[system] Pick files opens the Picker host with a minted token, files only, and records the pick" do
    with_connect_env do
      with_picker_key do
        store_google(scope: "openid #{DRIVE}", abilities: [ :drive ])
        google_answers(200, { access_token: "ya29.picker-session" })
        google_reads("#{GoogleConnect::DriveReader::FILES_URL}/f1" => [ 200, { id: "f1", name: "Q3 plan", mimeType: "application/pdf" } ])

        visit integrations_path
        page.execute_script(STUB)
        within(CARD) { click_on "Pick files" }

        host = find("[data-test='drive-picker-host']", visible: :all)
        assert_equal "ya29.picker-session", host["data-token"]
        assert_equal "test-picker-key", host["data-key"]
        assert_equal "1234567", host["data-app-id"]
        assert_equal "multi,drives", host["data-features"]
        assert_equal "false", host["data-folders"], "files only: Google grants no folder contents under drive.file"

        page.execute_script("window.__pickerCallback({ action: 'picked', docs: [{ id: 'f1' }] })")

        assert_text "1 file shared with your agents."
        assert_selector "#{CARD} [data-test='drive-pick'][data-file-id='f1']", text: "Q3 plan"
        assert_equal [ "f1" ], GoogleDrivePick.pluck(:file_id)
      end
    end
  ensure
    reset_google_connect
  end

  test "[system] a refused token shows its message on the card and opens no Picker" do
    with_connect_env do
      with_picker_key do
        store_google(scope: "openid #{DRIVE}", abilities: [ :drive ])
        google_answers(400, { error: "invalid_grant" })

        visit integrations_path
        page.execute_script(STUB)
        within(CARD) { click_on "Pick files" }

        assert_selector "#{CARD} [data-test='drive-picker-status']", text: /Google no longer accepts this connection/
        assert_no_selector "[data-test='drive-picker-host']", visible: :all
      end
    end
  ensure
    reset_google_connect
  end
end
