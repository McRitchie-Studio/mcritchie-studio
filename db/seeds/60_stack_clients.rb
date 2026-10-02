# McRitchie Studio's clients, as /stack shows them: tier, domain, and the two
# details the page leads with. The software strip is DERIVED (tier + credential
# records + extra_software). A priced tier provisions its own software, so only
# the two internal stacks list theirs here: an internal tier provisions nothing,
# and without it Studio and Industries would read as running nothing at all.
# Those lists come from the 2026-09-30 software inventory (production config and
# code, read-only) in .agents/epics/pricing-tiers-v2.md.
#
# Column order on /stack/matrix is Mr. McRitchie's (2026-10-01): us first
# (Studio, Industries), then Commercial Welding, Turf Monster, Cyvasse, 10and5.
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
  { slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL, domain: "mcritchie.studio", position: 10,
    resend_mode: "ms",
    extra_software: %w[google resend squarespace zerobounce heroku github postgres redis cloudflare aws
                       sentry anthropic openai discord 1password] },
  { slug: "industries", name: "McRitchie Industries", tier: StackClient::INTERNAL, domain: "mcritchie.industries",
    position: 20,
    # Google is its live Workspace. Its Slack pull exists in code but has no
    # production key (inventory 2026-09-30), so Slack is left off until it runs.
    extra_software: %w[google resend heroku github postgres cloudflare aws 1password] },
  { slug: "commercial-welding", name: "Commercial Welding", tier: "growth", domain: "commercialwelding.llc",
    # Workspace only today: no app yet.
    position: 30, notes: CONFIRMED_TIER },
  { slug: "turf-monster", name: "Turf Monster", tier: "growth", domain: "turfmonster.media", position: 40,
    # Sends from turfmonster.media through Resend on the Studio account (the key
    # is agent.resend in studio-agents).
    resend_mode: "ms", notes: CONFIRMED_TIER },
  { slug: "cyvasse", name: "Cyvasse", tier: "pro", domain: "cyvasse.xyz", position: 50, notes: CONFIRMED_TIER },
  # 10and5 lives at a mcritchie.studio subdomain, so it has no domain of its own.
  { slug: "10and5", name: "10&5 Hospitality", tier: "vibe", position: 60, notes: CONFIRMED_TIER }
].each do |attrs|
  client = StackClient.find_or_initialize_by(slug: attrs[:slug])
  client.update!(attrs)
end

puts "  #{StackClient.count} clients"
