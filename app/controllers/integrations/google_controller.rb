module Integrations
  # Any signed-in user's OWN Google connection, from the /integrations
  # Calendar, Gmail and Drive cards (/tasks/every-user-connects-google).
  # Connect sends them to Google through the shared flow (GoogleSignIn);
  # Google comes back to the one registered callback
  # (Admin::GoogleController#callback), which stores the connection as
  # theirs. Disconnect reaches only the rows they own: another user's
  # connection, the household's included, is never touched from here.
  #
  # A non-admin's connection is theirs alone: agents read only the household's
  # (GoogleConnection.household), never one made here by a non-admin.
  class GoogleController < ApplicationController
    include GoogleSignIn

    def connect = start_google_sign_in

    def disconnect = disconnect_google(current_user.google_connections)
  end
end
