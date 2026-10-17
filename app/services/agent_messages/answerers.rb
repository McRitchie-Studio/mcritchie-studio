module AgentMessages
  # Who the agents answer: the ROLES config/agent_answerers.yml lists
  # (docs/agents/modules/agent-communication.md; docs/agents/system/agent-message-loop.md,
  # "Held"). A person is answered when their role (AgentPerson#role, set by an
  # operator, never by a message) is one of them. Today the list is owner only,
  # which is the owner-only allow-list folded into the owner role: Alex is
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
  # BuildIntake): its soul (Xan) answers ANY person, the public included, on a
  # `web` row whose thread key starts with web:build:, and nowhere else. The
  # prefix is pinned to BuildIntake::THREAD_PREFIX at load, so a config typo can
  # never open a wider set of threads. The caps are BuildIntake::Caps, enforced
  # where those rows are written (BuildIntake::Ingest).
  class Answerers
    PATH = Rails.root.join("config/agent_answerers.yml")

    class Invalid < StandardError; end

    # The public-intake block, checked. Integers are the caps BuildIntake::Caps reads.
    PublicIntake = Struct.new(:soul, :thread_prefix, :turns_per_request, :signed_in_turns_per_request,
                              :per_ip_per_hour, :daily_total, keyword_init: true)
    INTAKE_CAPS = %w[turns_per_request signed_in_turns_per_request per_ip_per_hour daily_total].freeze

    attr_reader :roles, :public_intake

    class << self
      def load(path = PATH)
        config = YAML.safe_load_file(path, aliases: false)
        raise Invalid, "#{path} must hold answered_roles: [ ... ]" unless config.is_a?(Hash) && config.key?("answered_roles")

        new(config["answered_roles"], public_intake: config["public_intake"])
      end

      # The process's list, read once. Tests swap it with `current=` and `reset!`.
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(roles, public_intake: nil)
      raise Invalid, "answered_roles must be a list, got #{roles.inspect}" unless roles.is_a?(Array)

      @roles = roles.map(&:to_s).uniq
      unknown = @roles - AgentPerson::ROLES
      raise Invalid, "unknown role(s) #{unknown.join(', ')}; roles are #{AgentPerson::ROLES.join(', ')}" if unknown.any?

      @public_intake = public_intake.nil? ? nil : self.class.intake_config(public_intake)
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
    # (intake?) is answered whoever wrote it; a row with no person never is.
    def allowed?(person, message: nil)
      return false if person.blank?

      roles.include?(person.role) || (message.present? && intake?(message))
    end

    # The soul that answers public intake, or nil when there is none.
    def public_intake_soul = public_intake&.soul

    # Whether `message` (an AgentMessage, or anything with channel, soul_slug and
    # thread_key) is a public-intake row: the web channel, the intake soul, a
    # build thread. Nothing else, so the public is answered nowhere else.
    def intake?(message)
      return false unless public_intake

      message.channel.to_s == "web" && message.soul_slug.to_s == public_intake.soul &&
        message.thread_key.to_s.start_with?(public_intake.thread_prefix)
    end

    # The answered AgentPerson ids, read now: a role changed since is seen at once.
    def person_ids = roles.empty? ? [] : AgentPerson.where(role: roles).order(:id).pluck(:id)

    # Why a message from `person` is held, for its `held` event.
    def held_reason(person)
      role = person&.role || "none"
      "sender's role (#{role}) is not answered; config/agent_answerers.yml answers #{roles.join(', ').presence || 'nobody'}"
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
        if intake
          prefix = intake.thread_prefix
          clause += " OR (#{table}.person_id IS NOT NULL AND #{table}.channel = 'web' " \
                    "AND #{table}.soul_slug = #{conn.quote(intake.soul)} " \
                    "AND left(#{table}.thread_key, #{prefix.length}) = #{conn.quote(prefix)})"
        end
        "(#{clause})"
      end
    end
  end
end
