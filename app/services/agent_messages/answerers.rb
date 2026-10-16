module AgentMessages
  # Who the agents answer: config/agent_answerers.yml, read into the set of
  # AgentPerson ids it allows (docs/agents/system/agent-message-loop.md, "Held").
  #
  # A STOPGAP, owner-only, until agent-sender-authority replaces it with roles.
  # DiscordIngest stores an addressed message from anyone else as `held`, and
  # AgentMessage.claimable refuses any row whose person is not allowed unless an
  # admin released its hold, so the guard holds on the server even for a row
  # that is somehow `received`.
  #
  # An entry names a person by `person_id` or by `identity` (platform +
  # external_id). An identity matches the PERSON that holds it, so every identity
  # later linked to that person is allowed too. FAIL CLOSED: an identity no
  # person holds yet allows nobody, and a row with no person is never allowed.
  class Answerers
    PATH = Rails.root.join("config/agent_answerers.yml")

    class Invalid < StandardError; end

    Entry = Struct.new(:name, :person_id, :platform, :external_id, keyword_init: true)

    attr_reader :entries

    class << self
      def load(path = PATH)
        new(Array((YAML.safe_load_file(path, aliases: false) || {})["answerers"]))
      end

      # The process's list, read once. Tests swap it with `current=` and `reset!`.
      def current = @current ||= load

      attr_writer :current

      def reset! = @current = nil
    end

    def initialize(entries)
      @entries = entries.map { |raw| parse(raw) }
    end

    # The allowed AgentPerson ids, read from the identities now: an identity
    # linked or created since is seen on the next call.
    def person_ids
      ids = entries.filter_map(&:person_id)
      pairs = entries.select(&:platform)
      if pairs.any?
        scope = pairs.map { |e| AgentPersonIdentity.where(platform: e.platform, external_id: e.external_id) }.reduce(:or)
        ids += scope.pluck(:agent_person_id)
      end
      ids.uniq.sort
    end

    def allowed?(person) = person.present? && person_ids.include?(person.id)

    private

    def parse(raw)
      raise Invalid, "an answerer entry must be a mapping, got #{raw.inspect}" unless raw.is_a?(Hash)

      identity = raw["identity"]
      person_id = raw["person_id"]
      if identity.is_a?(Hash) && identity["platform"].present? && identity["external_id"].present?
        Entry.new(name: raw["name"], platform: identity["platform"].to_s, external_id: identity["external_id"].to_s)
      elsif person_id.to_s.match?(/\A\d+\z/)
        Entry.new(name: raw["name"], person_id: person_id.to_i)
      else
        raise Invalid, "answerer #{raw['name'].inspect} needs person_id or identity: { platform, external_id }"
      end
    end
  end
end
