module GoogleConnect
  # The Google Picker's settings (/tasks/drive-files-you-pick): the dialog in
  # which a person chooses the Drive files their agents may read under the
  # drive.file permission.
  #
  # The Picker runs in the browser and needs three things there:
  #
  #   a browser API key  GOOGLE_PICKER_API_KEY, read by NAME. Google makes it
  #                      public by design; it is restricted in the Cloud console
  #                      to https://mcritchie.studio/* and the Picker API. The
  #                      hub hands it out only from the token endpoint, beside
  #                      the token, never in page HTML.
  #   the app id         the Cloud project number, which is the digits that lead
  #                      the connections OAuth client id (GOOGLE_CONNECT_CLIENT_ID).
  #                      With it, Google grants the picked files to the app.
  #                      GOOGLE_PICKER_APP_ID overrides it.
  #   an access token    minted per request for the viewer's own connection
  #                      (Integrations::DrivePicksController#token). Short-lived;
  #                      the refresh token never leaves the server.
  module Picker
    API_KEY_ENV = "GOOGLE_PICKER_API_KEY".freeze
    APP_ID_ENV = "GOOGLE_PICKER_APP_ID".freeze
    LOADER_URL = "https://apis.google.com/js/api.js".freeze
    NOT_SET = "Drive picking isn't set up yet: this server has no Picker API key (#{API_KEY_ENV}).".freeze

    # Does picking a folder under drive.file grant the app its contents?
    # Google's docs do not say so and the one first-hand report says no
    # (the folder evidence note on drive-files-you-pick), so the Picker offers
    # files only. Flip this only on a live proof that a picked folder's
    # children list with the minted token.
    FOLDERS_GRANT_CHILDREN = false

    module_function

    def api_key = ENV[API_KEY_ENV].presence

    def app_id = ENV[APP_ID_ENV].presence || OAuthClient.client_id.to_s[/\A(\d+)-/, 1]

    # Can the Picker open here: a key, and an app id to grant the files to?
    def configured? = api_key.present? && app_id.present?
  end
end
