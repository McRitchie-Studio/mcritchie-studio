# McRitchie Studio's clients, as /stack shows them: tier, domain, and the two
# details the page leads with. The software strip is DERIVED (tier + credential
# records + extra_software), so it is not seeded here.
#
# This repo is PUBLIC: a client's name and domain belong here (both are already
# published in config/workspace_icons.yml); a contact, an email address or a
# price agreement does not.
#
# Tiers follow the v2 ladder Mr. McRitchie approved on 2026-09-30 (Vibe, Pro,
# Growth, Enterprise), whose comps are these clients: Turf Monster and
# Commercial Welding on Growth, Cyvasse on Pro, 10and5 on Vibe. McRitchie
# Industries is the Enterprise comp but is ours, so it stays internal. Google
# user counts are unknown and left blank rather than guessed.
#
# Idempotent: re-running updates rows in place and never deletes one.
puts "\n--- Stack clients ---"

CONFIRMED_TIER = "Tier confirmed by Mr. McRitchie 2026-09-30 (pricing tiers v2).".freeze

[
  { slug: "turf-monster", name: "Turf Monster", tier: "growth", domain: "turfmonster.media", position: 10,
    # Sends from turfmonster.media through Resend on the Studio account (the key
    # is agent.resend in studio-agents).
    resend_mode: "ms", notes: CONFIRMED_TIER },
  { slug: "commercial-welding", name: "Commercial Welding", tier: "growth", domain: "commercialwelding.llc",
    # Workspace only today: no app yet.
    position: 20, notes: CONFIRMED_TIER },
  { slug: "cyvasse", name: "Cyvasse", tier: "pro", domain: "cyvasse.xyz", position: 30, notes: CONFIRMED_TIER },
  # 10and5 lives at a mcritchie.studio subdomain, so it has no domain of its own.
  { slug: "10and5", name: "10&5 Hospitality", tier: "vibe", position: 40, notes: CONFIRMED_TIER },
  { slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL, domain: "mcritchie.studio", position: 90,
    resend_mode: "ms" },
  { slug: "industries", name: "McRitchie Industries", tier: StackClient::INTERNAL, domain: "mcritchie.industries",
    position: 91 }
].each do |attrs|
  client = StackClient.find_or_initialize_by(slug: attrs[:slug])
  client.update!(attrs)
end

puts "  #{StackClient.count} clients"
