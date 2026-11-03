module AgentChat
  # Who a satellite says is chatting, as the HUB decides it. The app sends
  # `person`: `{email}` when its visitor is signed in, else `{anon_token}` (its own
  # signed cookie). A signed-in post may carry both: the anon thread then folds
  # into the person's (AgentChat::Ingest#fold!).
  #
  #   email a hub User proved    the user's web person (WebIngest.person_for),
  #                              thread chat:<soul>:<user id>
  #   any other email            the person its `email` identity names, else a
  #                              new public one (AgentPerson.resolve!, as email
  #                              ingest), thread chat:<soul>:person:<id>
  #   anon_token                 a public "Visitor" person (web identity
  #                              ANON_PLATFORM_PREFIX + digest, also the rows'
  #                              author_ref), thread chat:<soul>:anon:<digest>
  #
  # Never matched by name, and never a role higher than the person already has:
  # a new person is public. The app's credential vouches for the email, as the
  # session vouches for the user on the hub's own chat.
  class Visitor
    class Invalid < StandardError; end

    EMAIL_MAX = 254
    ANON_REF_PREFIX = "chat-anon:".freeze

    attr_reader :soul, :email, :anon_digest, :user

    # `person`: the request's person param (a Hash or ActionController::Parameters).
    def self.from_param(soul, person)
      person = person.respond_to?(:to_unsafe_h) ? person.to_unsafe_h : person
      raise Invalid, "person must be {email} or {anon_token}" unless person.is_a?(Hash)

      new(soul, email: person["email"] || person[:email], anon_token: person["anon_token"] || person[:anon_token])
    end

    def initialize(soul, email: nil, anon_token: nil)
      @soul = soul.to_s
      @email = normalize_email(email)
      token = anon_token.to_s.strip
      raise Invalid, "person.anon_token is not a token" if token.present? && !token.match?(AgentChat::ANON_TOKEN)

      @anon_digest = token.present? ? AgentChat.anon_digest(token) : nil
      raise Invalid, "person must carry an email or an anon_token" unless @email || @anon_digest

      # Only a proven address names a hub user. /profile saves any address typed, and a
      # claimed one would take the owner's thread: its messages, and the answers to them.
      @user = @email ? User.where("lower(email) = ?", @email).where.not(email_verified_at: nil).first : nil
    end

    def signed_in? = @email.present?

    # The thread key, read without making a person: nil for an email with no
    # hub User and no person yet (it has no thread).
    def thread_key
      return AgentChat.user_thread_key(soul, user.id) if user
      return AgentChat.anon_thread_key(soul, anon_digest) unless signed_in?

      person = existing_email_person
      person && AgentChat.person_thread_key(soul, person.id)
    end

    # The thread key, making the person when this is their first message.
    def thread_key!
      return thread_key if user || !signed_in?

      AgentChat.person_thread_key(soul, person!.id)
    end

    # The anon thread a signed-in post folds in, or nil.
    def anon_thread_key = signed_in? && anon_digest ? AgentChat.anon_thread_key(soul, anon_digest) : nil

    # The AgentPerson this visitor's messages are from, made on first use.
    def person!
      return AgentMessages::WebIngest.person_for(user) if user
      if signed_in?
        return AgentPerson.resolve!(platform: "email", external_id: email, display_name: email.split("@").first.to_s[0, 100])
      end

      AgentPerson.resolve!(platform: "web", external_id: anon_ref, display_name: "Visitor")
    end

    # The anon visitor's web identity and their rows' author_ref, so the fold's
    # AgentPerson#link_identity! finds every row and note the visitor wrote.
    def anon_ref = anon_digest && "#{ANON_REF_PREFIX}#{anon_digest}"

    # The author_ref a row carries: the user id, as every web chat, else
    # person:<id> for an email, else the anon ref.
    def author_ref
      return user.id.to_s if user
      return anon_ref unless signed_in?

      thread_key!.delete_prefix(AgentChat.soul_prefix(soul))
    end

    # Who a recognised voice is called in the prompt (AgentChat::Voice), or nil
    # for an anonymous visitor. A hub user by the engine's own naming, so the
    # chat and POST /voice/takes agree; any other vouched-for email by the
    # person it names, else what #person! will call them. Read only: it makes no
    # person, because the post may yet be refused. One line, as a name.
    def speaker_name
      return nil unless signed_in?
      return Studio::VoiceTranscription.speaker_name(user) if user

      (existing_email_person&.display_name.to_s.squish.presence || email.split("@").first.to_s)[0, 100]
    end

    def author_name = (user&.display_name.presence || (signed_in? ? email.split("@").first : "Visitor")).to_s[0, 200]

    private

    def normalize_email(value)
      value = value.to_s.strip.downcase
      return nil if value.empty?
      raise Invalid, "person.email is not an email address" unless value.length <= EMAIL_MAX && value.match?(URI::MailTo::EMAIL_REGEXP)

      value
    end

    def existing_email_person
      AgentPersonIdentity.find_by(platform: "email", external_id: email)&.person
    end
  end
end
