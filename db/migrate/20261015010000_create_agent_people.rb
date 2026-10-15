# Omnichannel memory for the agent mailbox (docs/agents/system/agent-message-loop.md,
# "Memory"): a PERSON is one identity across platforms, so a soul remembers Alex
# whether he writes in #release-notes, #lobster-tank or (later) email.
#
#   - agent_people: one person (display name, optional hub User).
#   - agent_person_identities: where that person speaks, (platform, external_id),
#     unique, so one Discord user id or one email address is one person. Linking a
#     second identity to a person is an explicit act (AgentPerson#link_identity!);
#     nothing merges people across platforms on its own.
#   - agent_person_notes: the durable facts an answer may return about its sender,
#     one row per fact (AgentPersonNote). Replaces agent_user_notes, which had no
#     writer; any rows it holds are carried over line by line before it is dropped.
#   - agent_messages.person_id, stamped at create and backfilled here from
#     (channel, author_ref); the ledger index moves from (channel, channel_ref,
#     author_ref) to the person.
#
# The data steps use bare table classes, not the app's models, so this migration
# still runs after the models change.
class CreateAgentPeople < ActiveRecord::Migration[8.1]
  OWNER_DISCORD_ID = "536552944271753216"
  OWNER_EMAIL = "alex@mcritchie.studio"
  NOTE_LENGTH = 200

  class Person < ActiveRecord::Base
    self.table_name = "agent_people"
  end

  class Identity < ActiveRecord::Base
    self.table_name = "agent_person_identities"
  end

  class Note < ActiveRecord::Base
    self.table_name = "agent_person_notes"
  end

  class Message < ActiveRecord::Base
    self.table_name = "agent_messages"
  end

  class UserNote < ActiveRecord::Base
    self.table_name = "agent_user_notes"
  end

  def up
    create_table :agent_people do |t|
      t.string :display_name, null: false
      t.references :user, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.timestamps
    end

    create_table :agent_person_identities do |t|
      t.references :agent_person, null: false, foreign_key: { on_delete: :cascade }
      t.string :platform, null: false
      t.string :external_id, null: false
      t.string :display_name
      t.timestamps
    end
    add_index :agent_person_identities, [ :platform, :external_id ], unique: true

    create_table :agent_person_notes do |t|
      t.references :agent_person, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :body, null: false
      t.string :fingerprint, null: false
      t.bigint :source_message_id
      t.string :soul_slug
      t.datetime :noted_at, null: false
      t.timestamps
    end
    add_index :agent_person_notes, [ :agent_person_id, :fingerprint ], unique: true
    add_index :agent_person_notes, [ :agent_person_id, :noted_at ]
    add_foreign_key :agent_person_notes, :agent_messages, column: :source_message_id, on_delete: :nullify

    add_reference :agent_messages, :person, foreign_key: { to_table: :agent_people, on_delete: :nullify }, index: false
    add_index :agent_messages, [ :soul_slug, :person_id, :created_at ], name: "index_agent_messages_on_person_ledger"
    remove_index :agent_messages, name: "index_agent_messages_on_ledger"

    [ Person, Identity, Note, Message, UserNote ].each(&:reset_column_information)
    seed_owner
    backfill_messages
    carry_user_notes
    drop_table :agent_user_notes
  end

  def down
    create_table :agent_user_notes do |t|
      t.string :channel, null: false
      t.string :author_ref, null: false
      t.string :display_name
      t.text :notes, null: false, default: ""
      t.timestamps
    end
    add_index :agent_user_notes, [ :channel, :author_ref ], unique: true

    add_index :agent_messages, [ :soul_slug, :channel, :channel_ref, :author_ref, :created_at ],
              name: "index_agent_messages_on_ledger"
    remove_index :agent_messages, name: "index_agent_messages_on_person_ledger"
    remove_reference :agent_messages, :person, foreign_key: { to_table: :agent_people }
    drop_table :agent_person_notes
    drop_table :agent_person_identities
    drop_table :agent_people
  end

  private

  # Alex's Discord id is Alex, linked to his hub user when one carries his email.
  def seed_owner
    return if Identity.exists?(platform: "discord", external_id: OWNER_DISCORD_ID)

    user_id = select_value("SELECT id FROM users WHERE LOWER(email) = #{quote(OWNER_EMAIL)} LIMIT 1")
    person = Person.create!(display_name: "Alex", user_id: user_id)
    Identity.create!(agent_person_id: person.id, platform: "discord", external_id: OWNER_DISCORD_ID, display_name: "Alex")
  end

  # One person per (channel, author_ref) the mailbox already holds, named by its
  # newest author_name; every such row is stamped with it.
  def backfill_messages
    pairs = Message.where.not(author_ref: [ nil, "" ]).distinct.pluck(:channel, :author_ref)
    pairs.each do |platform, external_id|
      person_id = person_for(platform, external_id) do
        Message.where(channel: platform, author_ref: external_id).order(id: :desc).pick(:author_name)
      end
      Message.where(channel: platform, author_ref: external_id).update_all(person_id: person_id)
    end
  end

  # Each non-blank line of a held note becomes one note, cut to NOTE_LENGTH.
  def carry_user_notes
    UserNote.find_each do |row|
      person_id = person_for(row.channel, row.author_ref) { row.display_name }
      row.notes.to_s.lines.map { |l| l.strip.gsub(/\s+/, " ")[0, NOTE_LENGTH] }.reject(&:empty?).each do |body|
        fingerprint = body.downcase.gsub(/[^[:alnum:]]+/, " ").strip
        next if fingerprint.empty? || Note.exists?(agent_person_id: person_id, fingerprint: fingerprint)

        Note.create!(agent_person_id: person_id, body: body, fingerprint: fingerprint,
                     noted_at: row.updated_at || Time.current)
      end
    end
  end

  def person_for(platform, external_id)
    found = Identity.find_by(platform: platform, external_id: external_id)
    return found.agent_person_id if found

    name = yield.to_s.strip.presence || "#{platform} #{external_id}"
    person = Person.create!(display_name: name[0, 100])
    Identity.create!(agent_person_id: person.id, platform: platform, external_id: external_id, display_name: name[0, 100])
    person.id
  end
end
