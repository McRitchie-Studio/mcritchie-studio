# The Google sign-in flow (GoogleConnection), shared by the two doors to it:
#
#   Admin::GoogleController         /admin/google: the household's connections
#                                   (admin-owned, the ones agents read)
#   Integrations::GoogleController  /integrations/google: any signed-in user's
#                                   own connections
#
# Connect sends the person to Google for the asked abilities' read scopes;
# the callback exchanges the code, refuses a grant without them, stores the
# connection OWNED BY THE SIGNED-IN USER (the refresh token encrypted) and
# comes back where Connect was pressed. No token, and no part of one, is
# rendered, flashed or logged.
#
# ONE CALLBACK for both doors: /admin/google_calendar/callback, the redirect
# URI the OAuth client registered first, so the Google Cloud console owes no
# change. It lives on Admin::GoogleController, admits any signed-in user
# (AdminWall::SIGNED_IN) and is reached only with the OAuth state a Connect
# put in that same session.
#
# CONNECT GOOGLE (?ability=all, GoogleConnection::ALL) asks for all three in
# one consent. Google shows a checkbox per scope, so a partial grant is not a
# refusal: the callback stores what was granted and says what was left
# unticked. Only a grant of none of them stores nothing.
#
# WHAT THE CALLBACK REFUSES (/tasks/google-connect-hardening-polish): a
# callback in a session whose signed-in user is not the one who pressed
# Connect (the state is bound to that user's id); an account Google does not
# report as verified (email_verified); a grant of none of the asked abilities;
# an account another user connected. Each refusal revokes the token Google
# just issued unless a stored connection already holds that account's grant
# (#refuse_grant says why). Two simultaneous sign-ins of one new account end
# as one row (GoogleConnection.store! looks again) and never a 500.
#
# WHERE IT COMES BACK. Each Connect and Disconnect takes ?return_to=, honoured
# only when it is exactly one of the person's return paths (never an open
# redirect): an admin's are /integrations and /admin/google, anyone else's
# /integrations alone. Connect keeps it in the session beside the OAuth state.
module GoogleSignIn
  extend ActiveSupport::Concern

  KEYS_NOT_SET = "Google connections are not set up on this server: " \
                 "#{GoogleConnect::OAuthClient::ENV_NAMES.join(' and ')} are not set.".freeze
  ENCRYPTION_NOT_SET = "This server cannot store a connection: its encryption keys are not set " \
                       "(#{GoogleConnection::ENCRYPTION_ENV.join(', ')}). Nothing was asked of Google.".freeze
  UNKNOWN_ABILITY = "Choose Google Calendar, Gmail or Google Drive to connect.".freeze
  # The only places Connect and Disconnect come back to. Exact paths, no prefix match.
  ADMIN_RETURN_PATHS = %w[/integrations /admin/google].freeze
  OWN_RETURN_PATHS = %w[/integrations].freeze

  # Can this server take a connection: an OAuth client (or the stand-in) and encryption keys?
  def self.connectable?
    (GoogleConnect::OAuthClient.configured? || !GoogleConnect::OAuthClient.sign_in_stand_in.nil?) &&
      GoogleConnection.encryption_ready?
  end

  private

  def start_google_sign_in
    back = google_return_to(params[:return_to])
    abilities = GoogleConnection.abilities_for(params[:ability])
    return redirect_to(back, alert: UNKNOWN_ABILITY) if abilities.nil?
    return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless GoogleConnection.encryption_ready?

    session[:google_connect_return_to] = back
    session[:google_connect_ability] = params[:ability].to_s
    session[:google_connect_user_id] = current_user.id
    redirect_to GoogleConnect::OAuthClient.authorize_url(redirect_uri: google_callback_url, state: new_google_state, abilities:),
                allow_other_host: true
  rescue GoogleConnect::OAuthClient::NotConfigured
    redirect_to back, alert: KEYS_NOT_SET
  end

  def finish_google_sign_in
    expected = session.delete(:google_connect_oauth_state).to_s
    started_by = session.delete(:google_connect_user_id)
    back = google_return_to(session.delete(:google_connect_return_to))
    requested = GoogleConnection.abilities_for(session.delete(:google_connect_ability))
    return render(plain: "OAuth state mismatch: start the connection again.", status: :bad_request) unless google_state_matches?(expected) && requested

    return redirect_to(back, alert: google_refusal(params[:error].to_s)) if params[:error].present?
    return refuse_other_starter(back) unless started_by.present? && started_by == current_user.id
    return redirect_to(back, alert: ENCRYPTION_NOT_SET) unless GoogleConnection.encryption_ready?

    grant = GoogleConnect::OAuthClient.exchange_code(code: params[:code], redirect_uri: google_callback_url)
    email = GoogleConnect::OAuthClient.email_from(grant)
    return refuse_grant(grant, nil, back, "Google did not say which account signed in, so nothing was saved. Start again.") if email.nil?
    return refuse_grant(grant, email, back, unverified(email)) unless GoogleConnect::OAuthClient.email_verified?(grant)

    granted = GoogleConnection.granted_abilities(grant, requested)
    return refuse_grant(grant, email, back, nothing_granted(email, requested)) if granted.empty?

    connection = GoogleConnection.store!(grant, email:, user: current_user, abilities: requested)
    redirect_to back, notice: connected_notice(connection.email, requested, granted)
  rescue GoogleConnection::TakenByAnotherUser => e
    Rails.logger.info("[google_connect] refused: account owned by another user, by=#{current_user.slug}")
    refuse_grant(grant, email, back, e.message)
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("[google_connect] refused: a simultaneous sign-in of the same account stored it first, by=#{current_user.slug}")
    refuse_grant(grant, email, back, "#{email} was connecting in another tab at the same moment. It is connected once; nothing else changed.")
  rescue ActiveRecord::RecordInvalid => e
    refuse_grant(grant, email, back, "Google answered, but the connection was not saved: #{e.record.errors.full_messages.to_sentence}.")
  rescue GoogleConnect::OAuthClient::NotConfigured
    redirect_to back, alert: KEYS_NOT_SET
  rescue GoogleConnect::OAuthClient::Error => e
    redirect_to back, alert: "Google refused to exchange the sign-in code (#{e.message}). Start again: a code works once."
  end

  # A callback reached in a session whose signed-in user is not the one who
  # pressed Connect (someone else signed in on this browser mid-flow): the
  # connection would land on the wrong person. Nothing is stored; the code is
  # exchanged only so its grant can be refused and revoked (refuse_grant).
  def refuse_other_starter(back)
    Rails.logger.info("[google_connect] refused: callback user differs from the one who pressed Connect, by=#{current_user.slug}")
    message = "This Google sign-in was started by someone else signed in on this browser, so nothing was connected. Press Connect again."
    grant = GoogleConnect::OAuthClient.exchange_code(code: params[:code], redirect_uri: google_callback_url) if params[:code].present?
    refuse_grant(grant, GoogleConnect::OAuthClient.email_from(grant.to_h), back, message)
  rescue GoogleConnect::OAuthClient::Error
    redirect_to back, alert: message
  end

  # Refuses a sign-in Google already granted: comes back with `message` and
  # revokes the just-issued token, so no grant the hub will not keep stays live
  # at Google. Google revokes per GRANT (every token the account gave this OAuth
  # client), so when a stored connection already holds this account the revoke
  # is skipped: it would cut that connection, and the refused token, never
  # stored, logged or shown, is simply dropped.
  def refuse_grant(grant, email, back, message)
    held = email.present? && GoogleConnection.exists?(email: email.to_s.downcase)
    revoked = grant.present? && !held && GoogleConnect::OAuthClient.revoke_grant(grant)
    Rails.logger.info("[google_connect] refused grant: held=#{held} revoked=#{revoked} by=#{current_user.slug}")
    redirect_to back, alert: message
  end

  def unverified(email)
    "Google has not verified #{email}, so it was not connected. Verify the address with Google, then connect again."
  end

  # Disconnects one ability from every connection in `scope` that grants it.
  # Google cannot revoke a single scope, so an account keeping other abilities
  # only forgets this one here; an account losing its last is revoked and
  # deleted. A row outside `scope` is never touched.
  def disconnect_google(scope)
    back = google_return_to(params[:return_to])
    ability = GoogleConnection.ability(params[:ability])
    return redirect_to(back, alert: UNKNOWN_ABILITY, status: :see_other) if ability.nil?

    name = GoogleConnection::ABILITY_NAMES.fetch(ability)
    dropped, revoked, deleted = disconnect_all(scope, ability)
    Rails.logger.info("[google_connect] disconnect ability=#{ability} by=#{current_user.slug} at=#{Time.current.utc.iso8601} " \
                      "dropped=#{dropped} deleted=#{deleted} revoked=#{revoked}")
    redirect_to back, notice: disconnect_notice(name, dropped, revoked, deleted), status: :see_other
  end

  # Returns [scopes dropped, tokens revoked, rows deleted].
  def disconnect_all(scope, ability)
    dropped = revoked = deleted = 0
    scope.to_a.select { |connection| connection.can?(ability) }.each do |connection|
      if (connection.abilities - [ ability ]).any?
        connection.drop!(ability)
        dropped += 1
      else
        revoked += 1 if GoogleConnect::OAuthClient.revoke(connection)
        deleted += GoogleConnection.where(id: connection.id).delete_all
      end
    end
    [ dropped, revoked, deleted ]
  end

  def disconnect_notice(name, dropped, revoked, deleted)
    if dropped.zero? && deleted.zero? then "#{name} was not connected, so nothing changed."
    elsif deleted.zero? then "#{name} disconnected here. The account's other Google connections stay."
    elsif revoked == deleted then "#{name} disconnected: deleted here and revoked at Google."
    else "#{name} disconnected here. Google did not confirm the revoke; remove access at myaccount.google.com to be sure."
    end
  end

  def google_ability_names(abilities) = abilities.map { GoogleConnection::ABILITY_NAMES.fetch(_1) }

  def nothing_granted(email, requested)
    if requested.one?
      "Google signed in #{email} but did not grant #{google_ability_names(requested).first}: its permission was unticked. " \
        "Nothing was saved. Connect again and leave it ticked."
    else
      "Google signed in #{email} but granted none of " \
        "#{google_ability_names(requested).to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')}: " \
        "every permission was unticked. Nothing was saved. Connect again and leave them ticked."
    end
  end

  # What connected, and for Connect Google what was left unticked.
  def connected_notice(email, requested, granted)
    notice = "#{google_ability_names(granted).to_sentence} connected for #{email}."
    unticked = requested - granted
    return notice if unticked.empty?

    "#{notice} #{google_ability_names(unticked).to_sentence} #{unticked.one? ? 'was' : 'were'} left unticked, " \
      "so #{unticked.one? ? 'it stays' : 'they stay'} off."
  end

  def google_refusal(code)
    return "The sign-in was declined on Google. Nothing was connected." if code == "access_denied"

    "Google refused the sign-in (#{code[0, 100]}). Check the OAuth client's redirect URI, then start again."
  end

  # A return path only when it is exactly one of this person's; otherwise their home for Google.
  def google_return_to(value)
    paths = admin? ? ADMIN_RETURN_PATHS : OWN_RETURN_PATHS
    paths.include?(value) ? value : (admin? ? admin_google_path : integrations_path)
  end

  def google_state_matches?(expected)
    params[:state].present? && expected.present? &&
      ActiveSupport::SecurityUtils.secure_compare(params[:state].to_s, expected)
  end

  def new_google_state
    SecureRandom.hex(16).tap { |state| session[:google_connect_oauth_state] = state }
  end

  # The path the OAuth client registered first (/admin/google_calendar/callback),
  # for both doors: kept, so the Google Cloud console owes no change.
  def google_callback_url = admin_google_callback_url
end
