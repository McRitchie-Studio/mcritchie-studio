# The explicit acts on agent people (docs/agents/system/agent-message-loop.md,
# "Memory"). Nothing links identities on its own; these are how an operator does.
#
#   bin/rails agent_people:list
#   bin/rails agent_people:link PERSON=<id> PLATFORM=email EXTERNAL_ID=alex@example.com [REASSIGN=1]
#   bin/rails agent_people:notes PERSON=<id>
#   bin/rails agent_people:forget NOTE=<id>          (one note)
#   bin/rails agent_people:forget PERSON=<id> ALL=1  (every note the person has)
namespace :agent_people do
  desc "List agent people with their identities and note counts"
  task list: :environment do
    AgentPerson.includes(:identities).order(:id).each do |person|
      ids = person.identities.sort_by(&:id).map { |i| "#{i.platform}:#{i.external_id}" }.join(" ")
      puts "##{person.id} #{person.display_name}#{" (user #{person.user_id})" if person.user_id} #{ids} " \
           "notes=#{person.notes.count}"
    end
  end

  desc "Link an identity (PLATFORM + EXTERNAL_ID) to an existing person (PERSON); REASSIGN=1 moves one held elsewhere"
  task link: :environment do
    person = AgentPerson.find(ENV.fetch("PERSON"))
    identity = person.link_identity!(platform: ENV.fetch("PLATFORM"), external_id: ENV.fetch("EXTERNAL_ID"),
                                     reassign: ENV["REASSIGN"] == "1")
    puts "linked #{identity.platform}:#{identity.external_id} to ##{person.id} #{person.display_name}"
  rescue AgentPerson::LinkRefused, KeyError => e
    abort "agent_people:link: #{e.message}"
  end

  desc "List one person's notes (PERSON) with id, date, source message and soul"
  task notes: :environment do
    person = AgentPerson.find(ENV.fetch("PERSON"))
    notes = person.notes.to_a
    puts "##{person.id} #{person.display_name}: #{notes.size} note(s)"
    notes.each do |note|
      puts "  note #{note.id}  #{note.noted_at&.to_date}  " \
           "#{note.source_message_id ? "from ##{note.source_message_id}" : 'no source'}  " \
           "#{note.soul_slug || '-'}  #{note.body}"
    end
  rescue KeyError, ActiveRecord::RecordNotFound => e
    abort "agent_people:notes: #{e.message}"
  end

  desc "Delete one note (NOTE=<id>), or every note of a person (PERSON=<id> ALL=1)"
  task forget: :environment do
    if ENV["NOTE"].present?
      note = AgentPersonNote.find(ENV["NOTE"])
      note.destroy!
      puts "forgot note #{note.id} of ##{note.agent_person_id}: #{note.body}"
    elsif ENV["PERSON"].present? && ENV["ALL"] == "1"
      person = AgentPerson.find(ENV["PERSON"])
      count = person.notes.delete_all
      puts "forgot #{count} note(s) of ##{person.id} #{person.display_name}"
    else
      abort "agent_people:forget: pass NOTE=<id>, or PERSON=<id> ALL=1"
    end
  rescue ActiveRecord::RecordNotFound => e
    abort "agent_people:forget: #{e.message}"
  end
end
