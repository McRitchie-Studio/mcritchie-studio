module AgentMessages
  # Who the agents answer: the ROLES config/agent_answerers.yml lists
  # (docs/agents/modules/agent-communication.md; docs/agents/system/agent-message-loop.md,
  # "Held"). A person is answered when their role (AgentPerson#role, set by an
  # operator, never by a message) is one of them. Today the list is owner only,
  # which is the owner-only allow-list folded into the owner role: Alex McRitchie is
  # answered because his person is the owner, and every identity linked to him
  # with him.
  #
  # DiscordIngest stores an addressed message from anyone else as `held`, and
  # AgentMessage.claimable refuses any row whose person's role is not answered
  # unless an admin released its hold, so the guard holds on the server even for
  # a row that is somehow `received`. FAIL CLOSED: a row with no person is never
  # answered, and an empty list answers nobody.
  #
  # Answering a role is a separate question from what the agent may SAY to it:
  # once answered, AgentMailbox::Audience holds the answer to that role's rules.
  #
  # PUBLIC INTAKE is the one exception (`public_intake:` in the same file;
  # BuildIntake): its soul (Alex) answers ANY person, the public included, on a
  # `web` row whose thread key starts with web:build:, or with its own satellite
  # chat prefix (chat:<soul>:, AgentChat; Api::V1::AgentChatsController), and
  # nowhere else. The /build prefix is pinned to BuildIntake::THREAD_PREFIX at
  # load and the chat prefix is built in code, so a config typo can never open a
  # wider set of threads. The caps are BuildIntake::Caps, enforced
  # where those rows are written (BuildIntake::Ingest).
  #
  # APP OWNERS are the second exception (`app_owners:` in the same file; Alex McRitchie,
  # 2026-10-17): an app's CTO answers a person who OWNS that app, on that app's
  # web CTO thread and nowhere else (app_owner_thread?). Every fact it reads is
  # one code wrote: the row's channel (web), its channel_ref (the app, set by
  # WebIngest from the route), its thread key (web:<app>:<user id>, built by
  # WebChat.thread_key), its soul (the app's CTO, AppOwnership.cto_for_app), the
  # person's hub user, and that user's AppMembership. Nothing the message text
  # carries. The owner is answered as a CLIENT of the app (audience_for), never
  # as the owner or team, and within the app's usage meter (AgentUsage.owner_meter),
  # which WebIngest checks before a message is stored as answerable.
  class Answerers
    PATH = Rails.root.join("config/agent_answerers.yml")

    class Invalid < StandardError; end

    # The public-intake block, checked. Integers are the caps BuildIntake::Caps reads.
    PublicIntake = Struct.new(:soul, :thread_prefix, :turns_per_request, :signed_in_turns_per_request,
                              :per_ip_per_hour, :daily_total, keyword_init: true)
    INTAKE_CAPS = %w[turns_per_request signed_in_turns_per_request per_ip_per_hour daily_total].freeze
    # The app-owner block, checked. default_monthly_tokens caps an owner's
    # answers when the app's tier names no cto_monthly_tokens.
    AppOwners = Struct.new(:default_monthly_tokens, keyword_init: true)
    # The roles the app-owner exception answers, as a client. It never applies to
    # an owner or team person: they are answered, or held, by their role alone
    # (answered_roles), and spoken to as that role. A team-role app owner is held
    # on their own thread while the list answers owner only.
    APP_OWNER_ROLES = %w[public client].freeze

    attr_reader :roles, :public_intake, :app_owners

    class << self
      def load(path = PATH)
        config = YAML.safe_load_file(path, aliases: false)
        raise Invalid, "#{path} must hold answered_roles: [ ... ]" unless config.is_a?(Hash) && config.key?("answered_roles")

        new(config["answered_roles"], public_intake: config["public_intake"], app_owners: config["app_owners"])
      end

      # The process's list, read once. Tests swap it with `current=` and `reset!`.
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(roles, public_intake: nil, app_owners: nil)
      raise Invalid, "answered_roles must be a list, got #{roles.inspect}" unless roles.is_a?(Array)

      @roles = roles.map(&:to_s).uniq
      unknown = @roles - AgentPerson::ROLES
      raise Invalid, "unknown role(s) #{unknown.join(', ')}; roles are #{AgentPerson::ROLES.join(', ')}" if unknown.any?

      @public_intake = public_intake.nil? ? nil : self.class.intake_config(public_intake)
      @app_owners = app_owners.nil? ? nil : self.class.app_owners_config(app_owners)
    end

    def self.app_owners_config(raw)
      raise Invalid, "app_owners must be a map" unless raw.is_a?(Hash)

      tokens = raw["default_monthly_tokens"]
      raise Invalid, "app_owners.default_monthly_tokens must be a positive integer" unless tokens.is_a?(Integer) && tokens.positive?

      AppOwners.new(default_monthly_tokens: tokens)
    end

    def self.intake_config(raw)
      raise Invalid, "public_intake must be a map" unless raw.is_a?(Hash)

      soul = raw["soul"].to_s
      raise Invalid, "public_intake.soul must be a soul slug" unless soul.match?(/\A[a-z][a-z0-9_]{1,40}\z/)
      unless raw["thread_prefix"] == BuildIntake::THREAD_PREFIX
        raise Invalid, "public_intake.thread_prefix must be #{BuildIntake::THREAD_PREFIX.inspect}"
      end

      caps = INTAKE_CAPS.to_h do |key|
        value = raw[key]
        raise Invalid, "public_intake.#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?

        [ key.to_sym, value ]
      end
      PublicIntake.new(soul: soul, thread_prefix: BuildIntake::THREAD_PREFIX, **caps)
    end

    # Whether `person` is answered. With a `message`, a row public intake covers
    # (intake?) is answered whoever wrote it, and an app owner's row on their own
    # app's CTO thread (app_owner_thread?) is answered; a row with no person never is.
    def allowed?(person, message: nil)
      return false if person.blank?

      roles.include?(person.role) || (message.present? && (intake?(message) || app_owner_thread?(message, person)))
    end

    # Whether `person` is answered by their ROLE alone, with no exception.
    def role_answered?(person) = person.present? && roles.include?(person.role)

    # THE APP-OWNER RULE. True only when every one of these holds:
    #   - the exception is on (config has app_owners:)
    #   - the person's role is public or client (owner and team are their role)
    #   - the row is on the web channel
    #   - its thread key is exactly web:<channel_ref>:<the person's hub user id>
    #   - its soul is that app's CTO (AppOwnership.cto_for_app)
    #   - that user owns that app (AppMembership owner)
    # So another app's thread, Discord, email, /build, an app the person does not
    # own, or another user's thread on an app they do own are all false.
    # `message` is an AgentMessage, or anything with channel, channel_ref,
    # thread_key and soul_slug (WebIngest passes an unsaved probe).
    def app_owner_thread?(message, person = message.person)
      return false unless app_owners && person && APP_OWNER_ROLES.include?(person.role) && person.user_id
      return false unless message.channel.to_s == "web"

      app_slug = message.channel_ref.to_s
      return false if app_slug.empty? || message.thread_key.to_s != WebChat.thread_key(app_slug, person.user_id)

      self.class.owns_app_cto?(person.user_id, app_slug, message.soul_slug)
    end

    # Whether hub user `user_id` owns `app_slug` and `soul` is that app's CTO.
    def self.owns_app_cto?(user_id, app_slug, soul)
      return false if soul.blank? || AppOwnership.cto_for_app(app_slug)&.soul != soul.to_s

      user_slug = User.where(id: user_id).pick(:slug)
      user_slug.present? && AppMembership.owners.exists?(user_slug: user_slug, app_slug: app_slug.to_s)
    end

    # Whether `user` would be answered on `app_slug`'s CTO thread by the app-owner
    # rule, before they have a person (a new owner's first message makes one).
    def app_owner_user?(user, app_slug:, soul:)
      app_owners.present? && user.present? && self.class.owns_app_cto?(user.id, app_slug, soul)
    end

    # The audience a message is answered as ({"role", "client_domain"}): the
    # person's own (AgentPerson.audience_for), except on an app-owner thread,
    # where a public or client person is a CLIENT of that app, domain the app slug
    # underscored. Never higher than client: the exception grants no owner or team
    # action. Their `go` on that thread is ProposalConfirm#owner_verdict's to
    # decide (a change, under the cap), never confirm_proposal's. nil person: the public.
    def audience_for(message, person = message.person)
      base = AgentPerson.audience_for(person)
      return base unless person && app_owner_thread?(message, person)

      { "role" => "client", "client_domain" => message.channel_ref.to_s.tr("-", "_") }
    end

    # The soul that answers public intake, or nil when there is none.
    def public_intake_soul = public_intake&.soul

    # Whether `message` (an AgentMessage, or anything with channel, soul_slug and
    # thread_key) is a public-intake row: the web channel, the intake soul, a
    # build thread. Nothing else, so the public is answered nowhere else.
    def intake?(message)
      return false unless public_intake
      return false unless message.channel.to_s == "web" && message.soul_slug.to_s == public_intake.soul

      intake_prefixes.any? { |prefix| message.thread_key.to_s.start_with?(prefix) }
    end

    # The thread prefixes public intake answers on: /build's (pinned at load) and
    # the intake soul's satellite chat threads (AgentChat.soul_prefix: "chat:alex:"),
    # both built in code, never read from the message.
    def intake_prefixes
      return [] unless public_intake

      [ public_intake.thread_prefix, AgentChat.soul_prefix(public_intake.soul) ]
    end

    # The answered AgentPerson ids, read now: a role changed since is seen at once.
    def person_ids = roles.empty? ? [] : AgentPerson.where(role: roles).order(:id).pluck(:id)

    # Why a message from `person` is held, for its `held` event.
    def held_reason(person)
      role = person&.role || "none"
      line = "sender's role (#{role}) is not answered; config/agent_answerers.yml answers #{roles.join(', ').presence || 'nobody'}"
      app_owners ? "#{line} (and an app's owner on that app's own CTO chat only)" : line
    end

    # The guard as SQL, for AgentMessage.claimable: a proc from a table alias to
    # "that row may be answered". A row passes when an admin released its hold, or
    # its person's role is answered. The roles are checked against
    # AgentPerson::ROLES at load, and quoted besides; an empty list matches no person.
    #
    # Public intake adds one more way through, the SQL twin of intake?: a row on
    # the web channel, for the intake soul, whose thread key starts with the
    # pinned prefix (compared with left(), so no LIKE wildcard applies), that has
    # a person.
    def sql_guard
      conn = ActiveRecord::Base.connection
      list = roles.any? ? roles.map { |r| conn.quote(r) }.join(", ") : "NULL"
      intake = public_intake
      lambda do |table|
        clause = "#{table}.hold_released_at IS NOT NULL OR #{table}.person_id IN " \
                 "(SELECT agent_people.id FROM agent_people WHERE agent_people.role IN (#{list}))"
        clause += " OR #{app_owner_sql(table)}" if app_owners
        if intake
          prefixes = intake_prefixes.map { |prefix| "left(#{table}.thread_key, #{prefix.length}) = #{conn.quote(prefix)}" }
          clause += " OR (#{table}.person_id IS NOT NULL AND #{table}.channel = 'web' " \
                    "AND #{table}.soul_slug = #{conn.quote(intake.soul)} " \
                    "AND (#{prefixes.join(' OR ')}))"
        end
        "(#{clause})"
      end
    end

    private

    # The SQL twin of app_owner_thread?: the person is public or client and has a
    # hub user who owns the row's app; the thread key is exactly
    # web:<channel_ref>:<that user's id>; the soul is that app's CTO, a configured
    # one (config/cto_reports.yml) or, for an app it does not name, client_cto
    # with an app_ctos row.
    def app_owner_sql(table)
      conn = ActiveRecord::Base.connection
      # Read once per Answerers (per process, as the yml): the claim polls.
      configured = @configured_ctos ||= CtoReport.config.values
                                                 .select { |row| row.is_a?(Hash) && row["app"].present? && row["soul"].present? }
      pairs = configured.map { |row| "(#{conn.quote(row['soul'].to_s)}, #{conn.quote(row['app'].to_s)})" }
      apps = configured.map { |row| conn.quote(row["app"].to_s) }
      soul = "(#{table}.soul_slug = #{conn.quote(AppCto::SOUL)} " \
             "AND EXISTS (SELECT 1 FROM app_ctos WHERE app_ctos.app_slug = #{table}.channel_ref)" \
             "#{apps.any? ? " AND #{table}.channel_ref NOT IN (#{apps.join(', ')})" : ''})"
      soul = "((#{table}.soul_slug, #{table}.channel_ref) IN (#{pairs.join(', ')}) OR #{soul})" if pairs.any?
      roles = APP_OWNER_ROLES.map { |r| conn.quote(r) }.join(", ")
      "(#{table}.channel = 'web' AND #{soul} AND EXISTS (" \
        "SELECT 1 FROM agent_people owner_people " \
        "INNER JOIN users owner_users ON owner_users.id = owner_people.user_id " \
        "INNER JOIN app_memberships owner_memberships ON owner_memberships.user_slug = owner_users.slug " \
        "AND owner_memberships.role = 'owner' " \
        "WHERE owner_people.id = #{table}.person_id AND owner_people.role IN (#{roles}) " \
        "AND owner_memberships.app_slug = #{table}.channel_ref " \
        "AND #{table}.thread_key = 'web:' || owner_memberships.app_slug || ':' || owner_users.id::text))"
    end
  end
end
