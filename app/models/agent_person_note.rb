# One durable fact a soul keeps about a person (docs/agents/system/agent-message-loop.md,
# "Memory"): "Favorite color is purple." The USER layer of every answer to that
# person, on every channel, reads them.
#
# THE WRITER is the answer itself. The prompt lets the model return up to
# MAX_PER_ANSWER short facts about the sender after its reply (the worker strips
# them off; they are never posted), and AgentMessage#complete! hands them to
# record_from! with the message being completed. The facts are always filed under
# THAT message's author (message.person): the run answering Bea's message can only
# ever write notes about Bea, whatever the facts say.
#
# UNTRUSTED. A fact is model-written text derived from what a person said, so it
# is data: validated here (clean), stored as plain text, and rendered only inside
# the prompt's untrusted fence in the USER layer, never into GENERAL or DOMAIN.
# The caps keep a chatty or hostile sender from growing their notes without bound.
class AgentPersonNote < ApplicationRecord
  MAX_PER_ANSWER = 3
  MAX_PER_PERSON = 30
  MIN_LENGTH = 3
  MAX_LENGTH = 200
  # What a plain fact may not carry: a link, a mention or address (any @), a
  # Discord channel/role/user tag, markup or a code fence, control characters, or
  # the prompt's own fence marker.
  REJECT = %r{://|\bwww\.|@|<|>|`|untrusted-|[[:cntrl:]]}i

  belongs_to :person, class_name: "AgentPerson", foreign_key: :agent_person_id, inverse_of: :notes
  belongs_to :source_message, class_name: "AgentMessage", optional: true

  validates :body, presence: true, length: { maximum: MAX_LENGTH }
  validates :fingerprint, presence: true

  # Stores the facts a run returned for `message`, filed under its author.
  # Takes at most MAX_PER_ANSWER, drops any that fail clean or repeat a note the
  # person already has (or each other), then prunes the person's oldest notes past
  # MAX_PER_PERSON. Returns the notes stored. A message with no person stores none.
  def self.record_from!(message, facts, now: Time.current)
    person = message.person
    return [] unless person

    seen = person.notes.pluck(:fingerprint).to_set
    rows = Array(facts).first(MAX_PER_ANSWER).filter_map do |fact|
      body = clean(fact)
      next unless body

      print = fingerprint(body)
      next if print.empty? || !seen.add?(print)

      { agent_person_id: person.id, body: body, fingerprint: print, source_message_id: message.id,
        soul_slug: message.soul_slug, noted_at: now, created_at: now, updated_at: now }
    end
    return [] if rows.empty?

    ids = insert_all(rows, unique_by: %i[agent_person_id fingerprint], returning: :id).rows.flatten
    prune!(person)
    where(id: ids).order(:id).to_a
  end

  # The fact as it will be stored, or nil when it is not a plain short fact.
  def self.clean(fact)
    return nil unless fact.is_a?(String)

    body = fact.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
    return nil if body.length < MIN_LENGTH || body.length > MAX_LENGTH || body.match?(REJECT)

    body
  rescue ArgumentError, Encoding::CompatibilityError
    nil
  end

  # What two facts share when they say the same thing: lowercased words only.
  def self.fingerprint(body) = body.downcase.gsub(/[^[:alnum:]]+/, " ").strip

  # The person's newest MAX_PER_PERSON notes stay; older ones go.
  def self.prune!(person)
    stale = where(agent_person_id: person.id).order(noted_at: :desc, id: :desc).offset(MAX_PER_PERSON).pluck(:id)
    where(id: stale).delete_all if stale.any?
  end

  def as_api_json
    { "id" => id, "body" => body, "noted_at" => noted_at&.iso8601, "source_message_id" => source_message_id,
      "soul" => soul_slug }
  end
end
