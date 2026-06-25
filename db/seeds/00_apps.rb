# Managed-app registry seed. Idempotent upsert — safe on every deploy.
#
# `color` is each app's status-line tint (#RRGGBB). bin/statusline quantizes it to
# the nearest xterm-256 color and tints the app slug, so a glance tells you which
# app a session is in: McRitchie Studio reads lavender, Turf Monster green, etc.
# Colors are chosen to stay visually distinct after 256-color quantization.
# Mirrors docs/agents/modules/app-registry.md + the APP_OVERRIDES hash in
# bin/agent-worktree (display name + ports live there; color/emoji live here).
apps_data = [
  { slug: "mcritchie-studio", name: "McRitchie Studio", color: "#B57EDC", emoji: "🎩", position: 0,
    description: "Flagship hub, SSO source, recovery scripts, agent control plane." },
  { slug: "turf-monster", name: "Turf Monster", color: "#22C55E", emoji: "🏈", position: 1,
    description: "Sports pick'em satellite, payments, Solana integration." },
  { slug: "chain-ops", name: "Chain Ops", color: "#38BDF8", emoji: "⛓", position: 2,
    description: "Planned Solana localnet/QA/node operations control plane." },
  { slug: "studio-engine", name: "Studio Engine", color: "#94A3B8", emoji: "⚙️", position: 3,
    description: "Shared Rails engine for auth, theme, error logs, SSO." },
  { slug: "solana-studio", name: "Solana Studio", color: "#14F195", emoji: "☀️", position: 4,
    description: "Ruby Solana primitives." },
  { slug: "turf-vault", name: "Turf Vault", color: "#F59E0B", emoji: "🔐", position: 5,
    description: "Anchor smart contract." }
]

apps_data.each do |data|
  app = App.find_or_initialize_by(slug: data[:slug])
  app.assign_attributes(
    name: data[:name],
    color: data[:color],
    emoji: data[:emoji],
    description: data[:description],
    position: data[:position],
    status: "active"
  )
  app.save! if app.new_record? || app.changed?
  puts "App: #{app.name} (#{app.slug}) — #{app.color}"
end
