# One person the agents talk to, across every platform they speak on
# (docs/agents/system/agent-message-loop.md, "Memory"). A soul's memory of a
# person (the PERSON layer and the notes) follows the person, not the channel.
#
# WHERE A PERSON SPEAKS is an AgentPersonIdentity: (platform, external_id), a
# Discord user id today and an email address later, unique, so one id is one
# person. The first message from an unknown id makes a new person (resolve!).
#
# NO AUTO-MERGING. Nothing joins two identities into one person on its own: an
# email that happens to share a name with a Discord user stays a separate person
# until someone links it (link_identity!, from the console or
# `bin/rails agent_people:link`). A wrong merge would hand one person's memory to
# another, which is worse than a soul not recognising someone.
#
# A PERSON'S ROLE is who the agents are speaking with
# (docs/agents/modules/agent-communication.md): owner | team | client | public,
# default public, and for a client the domain (a key of config/agent_domains.yml)
# they are a client of. The audience of every answer is read from here, from the
# verified sender's person, never from what a message says. Only an operator sets
# it (set_role!, `bin/rails agent_people:role`).
require Rails.root.join("bin/lib/agent_audience").to_s

class AgentPerson < ApplicationRecord
  class LinkRefused < StandardError; end

  ROLES = AgentMailbox::Audience::ROLES
  DOMAINS_PATH = "config/agent_domains.yml"

  # Alex McRitchie: his Discord user id, and the hub user his email names.
  OWNER = { name: "Alex McRitchie", platform: "discord", external_id: "536552944271753216", email: "alex@mcritchie.studio" }.freeze
  # Alex McRitchie's hub accounts, one per app he owns (docs/agents/system/app-owners.md).
  # Each that exists is a `web` identity of the owner's person, so his CTO web
  # chat is answered as the owner from any of them (LinkOwnerWebIdentities).
  OWNER_HUB_EMAILS = %w[alex@mcritchie.studio alex@turfmonster.media amcritchie@gmail.com].freeze

  # Is this one of Alex McRitchie's own addresses? Since ritch-renamed-alex the
  # persona soul is slugged `alex`, so the local part of his mailbox
  # (alex@mcritchie.studio) spells an agent's slug. Every reader that turns an
  # email into a soul asks this first: the owner's address is the human, never
  # the agent (the agent keeps ray@mcritchie.studio).
  def self.owner_email?(email)
    OWNER_HUB_EMAILS.include?(email.to_s.strip.downcase)
  end

  belongs_to :user, optional: true
  has_many :identities, class_name: "AgentPersonIdentity", inverse_of: :person, dependent: :delete_all
  has_many :notes, -> { order(:noted_at, :id) }, class_name: "AgentPersonNote", inverse_of: :person,
                   dependent: :delete_all
  has_many :messages, class_name: "AgentMessage", foreign_key: :person_id, inverse_of: :person, dependent: :nullify

  validates :display_name, presence: true
  validates :role, inclusion: { in: ROLES }
  validates :client_domain, inclusion: { in: ->(_) { client_domains }, message: "is not a domain in #{DOMAINS_PATH}" },
                            if: -> { role == "client" }
  validates :client_domain, absence: { message: "is only for a client" }, unless: -> { role == "client" }

  # The domain keys a client may belong to: every domain not marked internal
  # (an internal domain is never named to anyone outside the team).
  def self.client_domains
    path = Rails.root.join(DOMAINS_PATH)
    config = File.file?(path) ? YAML.safe_load_file(path, aliases: false) : {}
    domains = config.is_a?(Hash) && config["domains"].is_a?(Hash) ? config["domains"] : {}
    domains.reject { |_, d| d.is_a?(Hash) && d["internal"] == true }.keys
  end

  # The audience of a message from `person` (nil: no author, so public), as the
  # context bundle carries it.
  def self.audience_for(person)
    (person ? AgentMailbox::Audience.new(role: person.role, client_domain: person.client_domain)
            : AgentMailbox::Audience.new(role: AgentMailbox::Audience::FALLBACK)).to_h
  end

  def audience = self.class.audience_for(self)

  # The operator's act that changes who this person is to the agents. A role
  # other than client clears the domain.
  def set_role!(role, client_domain: nil)
    role = role.to_s.strip
    update!(role: role, client_domain: role == "client" ? client_domain.to_s.strip.presence : nil)
  end

  # The person behind (platform, external_id), created with its identity when the
  # id is new. Race-safe: two ingests resolving one new id at once both get the
  # winner's person (the unique index decides, inside a savepoint). nil for a
  # blank id: a message with no author has no person.
  def self.resolve!(platform:, external_id:, display_name: nil)
    platform = platform.to_s
    external_id = external_id.to_s.strip
    return nil if platform.empty? || external_id.empty?

    found = AgentPersonIdentity.find_by(platform: platform, external_id: external_id)
    return found.person if found

    name = display_name.to_s.strip.presence || "#{platform} #{external_id}"
    transaction(requires_new: true) do
      person = create!(display_name: name[0, 100])
      person.identities.create!(platform: platform, external_id: external_id, display_name: name[0, 100])
      person
    end
  rescue ActiveRecord::RecordNotUnique
    AgentPersonIdentity.find_by!(platform: platform, external_id: external_id).person
  end

  # Alex McRitchie's person, his Discord identity, his email identity (alex@mcritchie.studio),
  # his hub user when one carries his email, and the owner role. Idempotent (db/seeds; the migration that made the tables seeds the
  # same rows): an existing identity keeps its person, and only a missing user
  # link is filled in.
  def self.seed_owner!
    person = resolve!(platform: OWNER[:platform], external_id: OWNER[:external_id], display_name: OWNER[:name])
    user = User.where("LOWER(email) = ?", OWNER[:email]).first
    person.update!(user: user) if user && person.user_id.nil? && !exists?(user_id: user.id)
    person.set_role!("owner") unless person.role == "owner"
    # His email, so a VERIFIED mail from it is answered as the owner
    # (AgentMessages::EmailIngest). Never moved off another person here.
    unless AgentPersonIdentity.exists?(platform: "email", external_id: OWNER[:email])
      person.identities.create!(platform: "email", external_id: OWNER[:email], display_name: OWNER[:name])
    end
    # His hub accounts, so the CTO web chat answers him as the owner from each.
    User.where("LOWER(email) IN (?)", OWNER_HUB_EMAILS).order(:id).pluck(:id).each do |user_id|
      next if AgentPersonIdentity.exists?(platform: "web", external_id: user_id.to_s)

      person.identities.create!(platform: "web", external_id: user_id.to_s, display_name: OWNER[:name])
    end
    person
  end

  # The explicit act that says "this id is also this person". Every stored
  # message from the id is restamped to this person, so its history joins the
  # PERSON layer at once. Refused when the id already belongs to someone else,
  # unless `reassign: true`; a reassign moves the identity, its messages, and the
  # notes those messages produced.
  #
  # WHY THE NOTES MOVE. A note is filed from the words of the message it came
  # from (source_message), so it is a fact about whoever wrote that message. Once
  # the id is someone else's, the facts it said belong with them too: left
  # behind, the old person would keep "facts" that were never about them, and
  # every soul would keep telling them so. A note the new person already has (same
  # domain and fingerprint) is dropped from the old person instead of duplicated; the new
  # person is then pruned to MAX_PER_PERSON per domain. Notes with no source message (carried
  # over from the old table) cannot be attributed and stay where they are.
  def link_identity!(platform:, external_id:, display_name: nil, reassign: false)
    platform = platform.to_s.strip
    external_id = external_id.to_s.strip
    raise LinkRefused, "platform and external_id are required" if platform.empty? || external_id.empty?

    transaction do
      identity = AgentPersonIdentity.lock.find_by(platform: platform, external_id: external_id)
      if identity.nil?
        identity = identities.create!(platform: platform, external_id: external_id, display_name: display_name)
      elsif identity.agent_person_id != id
        unless reassign
          raise LinkRefused, "#{platform}:#{external_id} belongs to person #{identity.agent_person_id} " \
                             "(#{identity.person.display_name}); pass reassign: true to move it"
        end
        identity.update!(agent_person_id: id)
      end
      spoken = AgentMessage.where(channel: platform, author_ref: external_id)
      move_notes_from!(spoken)
      spoken.update_all(person_id: id)
      identity
    end
  end

  # Notes held by OTHER people whose source message is in `messages` come here.
  def move_notes_from!(messages)
    moving = AgentPersonNote.where(source_message_id: messages.select(:id)).where.not(agent_person_id: id)
                            .order(:id).pluck(:id, :domain, :fingerprint)
    return if moving.empty?

    seen = notes.pluck(:domain, :fingerprint).to_set
    keep, drop = moving.partition { |_, domain, print| seen.add?([ domain, print ]) }
    AgentPersonNote.where(id: drop.map(&:first)).delete_all if drop.any?
    AgentPersonNote.where(id: keep.map(&:first)).update_all(agent_person_id: id, updated_at: Time.current)
    AgentPersonNote.prune!(self)
  end
  private :move_notes_from!

  def as_api_json(notes: true)
    data = { "id" => id, "display_name" => display_name, "user_id" => user_id, "role" => role,
             "client_domain" => client_domain,
             "identities" => identities.order(:id).map { |i| "#{i.platform}:#{i.external_id}" } }
    data["notes"] = self.notes.map(&:as_api_json) if notes
    data
  end
end
