# Alex as an agent person (AgentPerson.seed_owner!): his Discord id maps to him and
# to his hub user, so every soul's memory of him is one person across channels.
# Idempotent; safe on every run.
person = AgentPerson.seed_owner!
puts "Agent person: #{person.display_name} (##{person.id})#{" linked to user #{person.user_id}" if person.user_id}"
