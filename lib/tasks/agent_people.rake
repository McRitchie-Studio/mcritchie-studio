# The explicit acts on agent people (docs/agents/system/agent-message-loop.md,
# "Memory"). Nothing links identities on its own; these are how an operator does.
#
#   bin/rails agent_people:list
#   bin/rails agent_people:link PERSON=<id> PLATFORM=email EXTERNAL_ID=alex@example.com [REASSIGN=1]
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
end
