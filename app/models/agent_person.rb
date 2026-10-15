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
class AgentPerson < ApplicationRecord
  class LinkRefused < StandardError; end

  belongs_to :user, optional: true
  has_many :identities, class_name: "AgentPersonIdentity", inverse_of: :person, dependent: :delete_all
  has_many :notes, -> { order(:noted_at, :id) }, class_name: "AgentPersonNote", inverse_of: :person,
                   dependent: :delete_all
  has_many :messages, class_name: "AgentMessage", foreign_key: :person_id, inverse_of: :person, dependent: :nullify

  validates :display_name, presence: true

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

  # The explicit act that says "this id is also this person". Every stored
  # message from the id is restamped to this person, so its history joins the
  # PERSON layer at once. Refused when the id already belongs to someone else,
  # unless `reassign: true`; a reassign moves the identity and its messages, and
  # leaves the old person's notes where they are.
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
      AgentMessage.where(channel: platform, author_ref: external_id).update_all(person_id: id)
      identity
    end
  end

  def as_api_json(notes: true)
    data = { "id" => id, "display_name" => display_name, "user_id" => user_id,
             "identities" => identities.order(:id).map { |i| "#{i.platform}:#{i.external_id}" } }
    data["notes"] = self.notes.map(&:as_api_json) if notes
    data
  end
end
