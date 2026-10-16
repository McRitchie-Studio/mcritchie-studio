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
  class Answerers
    PATH = Rails.root.join("config/agent_answerers.yml")

    class Invalid < StandardError; end

    attr_reader :roles

    class << self
      def load(path = PATH)
        config = YAML.safe_load_file(path, aliases: false)
        raise Invalid, "#{path} must hold answered_roles: [ ... ]" unless config.is_a?(Hash) && config.key?("answered_roles")

        new(config["answered_roles"])
      end

      # The process's list, read once. Tests swap it with `current=` and `reset!`.
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(roles)
      raise Invalid, "answered_roles must be a list, got #{roles.inspect}" unless roles.is_a?(Array)

      @roles = roles.map(&:to_s).uniq
      unknown = @roles - AgentPerson::ROLES
      raise Invalid, "unknown role(s) #{unknown.join(', ')}; roles are #{AgentPerson::ROLES.join(', ')}" if unknown.any?
    end

    def allowed?(person) = person.present? && roles.include?(person.role)

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
    def sql_guard
      list = roles.any? ? roles.map { |r| ActiveRecord::Base.connection.quote(r) }.join(", ") : "NULL"
      lambda do |table|
        "(#{table}.hold_released_at IS NOT NULL OR #{table}.person_id IN " \
          "(SELECT agent_people.id FROM agent_people WHERE agent_people.role IN (#{list})))"
      end
    end
  end
end
