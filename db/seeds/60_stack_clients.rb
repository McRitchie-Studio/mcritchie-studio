# McRitchie Studio's clients, as /stack shows them: tier, domain, and the two
# details the page leads with. The software strip is DERIVED (tier + credential
# records + extra_software), so it is not seeded here.
#
# This repo is PUBLIC: a client's name and domain belong here (both are already
# published in config/workspace_icons.yml); a contact, an email address or a
# price agreement does not.
#
# Tiers for Turf Monster and Commercial Welding were PROPOSED on 2026-09-25 and
# not yet confirmed by Mr. McRitchie; the notes say so until he does. Google user
# counts are unknown and left blank rather than guessed.
#
# Idempotent: re-running updates rows in place and never deletes one.
puts "\n--- Stack clients ---"

UNCONFIRMED_TIER = "Tier proposed 2026-09-25; not yet confirmed.".freeze

[
  { slug: "turf-monster", name: "Turf Monster", tier: "agentic", domain: "turfmonster.media", position: 10,
    # Sends from turfmonster.media through Resend on the Studio account (the key
    # is agent.resend in studio-agents).
    resend_mode: "ms", notes: UNCONFIRMED_TIER },
  { slug: "commercial-welding", name: "Commercial Welding", tier: "workspace", domain: "commercialwelding.llc",
    position: 20, notes: UNCONFIRMED_TIER },
  { slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL, domain: "mcritchie.studio", position: 90,
    resend_mode: "ms" },
  { slug: "industries", name: "McRitchie Industries", tier: StackClient::INTERNAL, domain: "mcritchie.industries",
    position: 91 }
].each do |attrs|
  client = StackClient.find_or_initialize_by(slug: attrs[:slug])
  client.update!(attrs)
end

puts "  #{StackClient.count} clients"
