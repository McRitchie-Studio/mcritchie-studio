module Integrations
  # Any signed-in user's OWN Google connection, from the /integrations
  # Calendar, Gmail and Drive cards (/tasks/every-user-connects-google).
  # Connect sends them to Google through the shared flow (GoogleSignIn);
  # Google comes back to the one registered callback
  # (Admin::GoogleController#callback), which stores the connection as
  # theirs. Disconnect reaches only the rows they own: another user's
  # connection, the household's included, is never touched from here.
  #
  # Who reads a connection made here is GoogleConnection#who_reads: a client
  # app owner's own app agent in their own chat (/tasks/agent-reads-owner-google),
  # otherwise no agent; the household's agents never read it.
  class GoogleController < ApplicationController
    include GoogleSignIn

    def connect = start_google_sign_in

    def disconnect = disconnect_google(current_user.google_connections)
  end
end
