# One durable fact a soul keeps about a person (docs/agents/system/agent-message-loop.md,
# "Memory"): "Favorite color is purple." The USER layer of every answer to that
# person, on every channel, reads them.
#
# THE WRITER is the answer itself. The prompt lets the model return up to
# MAX_PER_ANSWER short facts about the sender after its reply (the worker cuts
# them off at the loose NoteBlock delimiter, and the board cuts again), and
# AgentMessage#complete! hands them to record_from! with the message being completed. The facts are always filed under
# THAT message's author (message.person): the run answering Bea's message can only
# ever write notes about Bea, whatever the facts say.
#
# UNTRUSTED. A fact is model-written text derived from what a person said, so it
# is data: validated here (clean: plain short text, and never a directive), stored as plain text, and rendered only inside
# the prompt's untrusted fence in the USER layer, never into GENERAL or DOMAIN.
# The caps keep a chatty or hostile sender from growing their notes without bound.
#
# SCOPED BY DOMAIN (Alex, 2026-10-15). Each note records `domain`: the app domain
# of the soul that filed it (config/agent_domains.yml `souls:`, "" for a soul the
# registry maps to none). Who reads it depends on the CURRENT sender's role when
# an answer is built (.visible_for): for an owner or team member every note is
# shared by every soul, as a fact about them is true whichever agent hears it;
# for a client or the public, a soul sees only the notes filed in its own domain,
# so what a Turf client told Turf stays with Turf.
class AgentPersonNote < ApplicationRecord
  MAX_PER_ANSWER = 3
  MAX_PER_PERSON = 30
  MIN_LENGTH = 3
  MAX_LENGTH = 200
  # The roles whose notes every soul shares across domains (.visible_for).
  SHARED_ROLES = %w[owner team].freeze
  # What a plain fact may not carry: a link, a mention or address (any @), a
  # Discord channel/role/user tag, markup or a code fence, control characters,
  # the prompt's own fence marker, or a square bracket. Brackets are refused
  # because the prompt prints a code-shaped provenance label beside each note
  # (`[discord #general]`, AgentMessages::MemoryBundle#place): a note carrying
  # brackets could imitate one. Text is NFKC-normalized first, so a fullwidth
  # bracket arrives as `[`; the lenticular and tortoise-shell lookalikes are
  # refused too.
  REJECT = %r{://|\bwww\.|@|<|>|`|untrusted-|[\[\]【】〔〕〘〙⟦⟧]|[[:cntrl:]]}i
  # The words a FACT never needs and an attempt on the agent's MACHINERY or
  # AUTHORITY always does: the prompt's own vocabulary (system, prompt,
  # instruction, rule, policy, guideline), a claim to authority (admin,
  # permission, access, allowed, approved, granted, privileged), a credential
  # paired with a right, and the attack verbs (disregard, override, bypass,
  # jailbreak). A note claiming "Has deploy access" or "The system prompt is
  # public" is refused.
  #
  # PLAIN WORDS ARE KEPT (Alex, 2026-10-15). The directive and answer-shape
  # words (always, never, ignore, forget, pretend, reply, respond, answer, you,
  # must, should, act as, end with, every message, in caps) were refused before;
  # they are ordinary English in real facts ("Never drinks coffee", "Prefers
  # short answers"), and a note reaches the prompt only inside the untrusted
  # fence, labeled as data. The one list; tests pin it.
  DIRECTIVES = [
    /\b(?:disregard\w*|override\w*|bypass\w*|jailbreak\w*)\b/i,
    /\b(?:system|prompt\w*|instruct\w*|rules?|polic(?:y|ies)|guidelines?)\b/i,
    /\b(?:admin\w*|permission\w*|access|allowed|permitted|authori[sz]\w*|approv\w*|privilege\w*|grant\w*|sudo|root)\b/i,
    /\b(?:deploy|merge|token|password|secret|credential)\w*\s+(?:access|rights|key|for|to)\b/i
  ].freeze

  belongs_to :person, class_name: "AgentPerson", foreign_key: :agent_person_id, inverse_of: :notes
  belongs_to :source_message, class_name: "AgentMessage", optional: true

  validates :body, presence: true, length: { maximum: MAX_LENGTH }
  validates :fingerprint, presence: true

  # Stores the facts a run returned for `message`, filed under its author.
  # Takes at most MAX_PER_ANSWER, drops any that fail clean or repeat a note the
  # person already has in the answering soul's domain (or each other), stamps
  # that domain on each, then prunes the person's oldest notes in it past
  # MAX_PER_PERSON. Returns the notes stored. A message with no person stores none.
  def self.record_from!(message, facts, now: Time.current)
    person = message.person
    return [] unless person

    domain = domain_for(message.soul_slug)
    seen = person.notes.where(domain: domain).pluck(:fingerprint).to_set
    rows = Array(facts).first(MAX_PER_ANSWER).filter_map do |fact|
      body = clean(fact)
      next unless body

      print = fingerprint(body)
      next if print.empty? || !seen.add?(print)

      { agent_person_id: person.id, body: body, fingerprint: print, source_message_id: message.id,
        soul_slug: message.soul_slug, domain: domain, noted_at: now, created_at: now, updated_at: now }
    end
    return [] if rows.empty?

    ids = insert_all(rows, unique_by: %i[agent_person_id domain fingerprint], returning: :id).rows.flatten
    prune!(person, domain: domain)
    where(id: ids).order(:id).to_a
  end

  # The fact as it will be stored, or nil when it is not a plain short fact.
  def self.clean(fact)
    return nil unless fact.is_a?(String)

    body = fact.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, " ").strip
    return nil if body.length < MIN_LENGTH || body.length > MAX_LENGTH || body.match?(REJECT) || directive?(body)

    body
  rescue ArgumentError, Encoding::CompatibilityError
    nil
  end

  # True when the text reaches for the agent's machinery or authority (DIRECTIVES).
  def self.directive?(body) = DIRECTIVES.any? { |pattern| body.match?(pattern) }

  # True when a stored body still passes clean unchanged: the bundle holds a note
  # stored under an older rule to today's (a bracket, a directive) before it can
  # reach a prompt.
  def self.admissible?(body) = clean(body) == body

  # The domain key a soul files and reads notes under: its entry in the souls
  # map, or "" when the registry names none.
  def self.domain_for(soul) = AgentProposal.registry.domain_key_for(soul).to_s

  # The notes about `person` that `soul` may read for a sender of `role` (the
  # person's role now, AgentPerson#role): every domain's for owner and team, the
  # soul's own domain's for client and public. Anything else reads as public.
  def self.visible_for(person, soul:, role:)
    scope = where(agent_person_id: person.id)
    SHARED_ROLES.include?(role.to_s) ? scope : scope.where(domain: domain_for(soul))
  end

  # What two facts share when they say the same thing: lowercased words only.
  def self.fingerprint(body) = body.downcase.gsub(/[^[:alnum:]]+/, " ").strip

  # The person's newest MAX_PER_PERSON notes in each domain stay; older ones go.
  # `domain:` prunes one domain; without it, every domain the person has notes in.
  def self.prune!(person, domain: nil)
    domains = domain.nil? ? where(agent_person_id: person.id).distinct.pluck(:domain) : [ domain ]
    domains.each do |key|
      stale = where(agent_person_id: person.id, domain: key).order(noted_at: :desc, id: :desc)
                .offset(MAX_PER_PERSON).pluck(:id)
      where(id: stale).delete_all if stale.any?
    end
  end

  def as_api_json
    { "id" => id, "body" => body, "noted_at" => noted_at&.iso8601, "source_message_id" => source_message_id,
      "soul" => soul_slug, "domain" => domain }
  end
end
