# Agent registry seed.
#
# Idempotent upsert: safe to run on every deploy (release → QA/prod). Each soul
# carries the Deploy-flow redesign roles + the metadata the `ReviewerSelector`
# reads when Carl summons a review light (see
# docs/agents/system/devops-cycle-design.md §1.2):
#
#   metadata["reviewer"]       — true if in the senior review pool
#   metadata["review_role"]    — "owner" | "reviewer" | "orchestrator" | nil
#   metadata["domains"]        — areas/repos this soul reviews (domain-fit input)
#   metadata["review_weight"]  — NUMERIC review weight (higher = wins the single
#                                LIGHT seat when two specialists tie on domain fit).
#                                Stored as a number, NOT the "heavy"/"light" label
#                                a bare String#to_f would silently zero (see
#                                ReviewerSelector::WEIGHT_LABELS). The specialists
#                                share the heavy weight; the light falls to fit then
#                                the logged roll. ReviewerSelector::WEIGHT_LABELS
#                                maps heavy->2.0 / light->1.0 for legacy label rows.
#
# Carl is the LEAD ARCHITECT and STANDING PRIMARY — the deep reviewer + OWNER on
# EVERY PR (there is no Avi supervisor). He summons ONE domain LIGHT from the
# specialist pool {Shannon=UI · Jasper=Web3 · Steffon=DevOps/Platform ·
# Alex=Documentation}. After the 2026-07-22 reslot **Avi** is the `qa_owner` (he runs
# qa-release: the accepted→release sweep + QA), so he is kept out of the light pool —
# no soul both reviews AND QAs the same change (no self-gating). Steffon moved to
# production-deploy and rejoined the light specialist pool. See
# docs/agents/agents/carl/sops/pr-review.md and app/services/reviewer_selector.rb.
agents_data = [
  {
    name: "Alex",
    slug: "alex",
    status: "active",
    agent_type: "orchestrator",
    title: "Lead Orchestrator",
    description: "Coordinates all agents, manages task assignment, and oversees system operations — the central brain of McRitchie Studio. Also holds the senior review pool's Documentation seat: reviews docs, runbooks, the agent operating model, and READMEs on PRs that touch them.",
    avatar: "/agents/alex.png",
    position: 0,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
      "domains" => ["documentation", "docs", "runbooks", "agent-operating-model", "readme"],
      "review_weight" => 2.0
    }
  },
  {
    name: "Avi",
    slug: "avi",
    status: "active",
    agent_type: "product",
    title: "Product Owner",
    description: "Product Owner and Deploy-flow assembler. Refines tickets, sets po_size, and owns the qa-release sweep: promote the accepted → release batch PR, run the pre-QA gate, deploy QA, and flip members assembled on QA-green. Review is Carl's; the ship is Steffon's.",
    avatar: "/agents/avi.png",
    position: 3,
    metadata: {
      "review_role" => nil,
      "reviewer" => false,
      "assembler" => true,
      "qa_owner" => true,
      "responsibilities" => ["ticket-refinement", "sizing", "qa-release", "qa-deploy"]
    }
  },
  {
    name: "Carl",
    slug: "carl",
    status: "active",
    agent_type: "specialist",
    title: "Lead Architect",
    description: "Lead Architect and owner of PR review. Crack Rails dev — controllers, models, migrations, background jobs, ActiveRecord performance, and the studio-engine internals. The STANDING PRIMARY on every PR: the deep reviewer who owns the gates, summons a domain light specialist at his discretion, drives the verdict, and merges approved work into the accepted branch.",
    avatar: "/agents/carl.png",
    position: 4,
    metadata: {
      "review_role" => "owner",
      "reviewer" => true,
      "standing_primary" => true,
      "domains" => ["backend", "models", "controllers", "migrations", "jobs", "studio-engine"],
      "review_weight" => 2.0
    }
  },
  {
    name: "Shannon",
    slug: "shannon",
    status: "active",
    agent_type: "specialist",
    title: "Dev UI Expert",
    description: "UI specialist. Owns frontend development across the ecosystem — ERB views, Tailwind, Alpine.js, theme system, and studio-engine UI primitives. Senior reviewer for UI PRs in the Deploy-flow review pool.",
    avatar: "/agents/shannon.png",
    position: 5,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
      "domains" => ["ui", "views", "tailwind", "alpine", "theme", "studio-engine-ui"],
      "review_weight" => 2.0
    }
  },
  {
    name: "Jasper",
    slug: "jasper",
    status: "active",
    agent_type: "specialist",
    title: "Dev Blockchain Expert",
    description: "Blockchain specialist. Owns the Solana surface: turf-vault Anchor program, solana-studio Ruby client, and all on-chain integration. Senior reviewer for Web3 / on-chain PRs in the Deploy-flow review pool.",
    avatar: "/agents/jasper.png",
    position: 6,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
      "domains" => ["web3", "solana", "turf-vault", "solana-studio", "on-chain", "anchor"],
      "review_weight" => 2.0
    }
  },
  {
    name: "Steffon",
    slug: "steffon",
    status: "active",
    agent_type: "specialist",
    title: "Platform Engineer",
    description: "Platform Engineer (Ship + Infrastructure). Owns production-deploy — the frozen-SHA ship gate, then bin/release ship (ff release → main, deploy prod, smoke, release notes) — plus archive-shipped, Heroku deploys, env vars, CI, observability, and the recovery protocol. Domain light reviewer for DevOps/Platform PRs. After the reslot the reviewer-select QA-owner exclusion keys on Avi (who runs qa-release), not on Steffon, so Steffon is back in the light pool.",
    avatar: "/agents/steffon.png",
    position: 7,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
      "domains" => ["devops", "release", "infrastructure", "ci", "observability", "heroku"],
      "review_weight" => 2.0,
      "ship_gate" => true
    }
  },
  {
    name: "Turf Monster",
    slug: "turf-monster",
    status: "active",
    agent_type: "specialist",
    title: "Sports Domain Specialist",
    description: "Specializes in sports data, pick'em games, and the Turf Monster app. Expert in World Cup props and player stats.",
    avatar: "/agents/turf-monster.png",
    position: 1,
    metadata: {
      "review_role" => nil,
      "reviewer" => false
    }
  },
  {
    name: "Mack",
    slug: "mack",
    status: "active",
    agent_type: "worker",
    title: "General Worker",
    description: "Versatile worker agent handling data scraping, processing, and general-purpose tasks. Reliable and efficient.",
    avatar: "/agents/mack.png",
    position: 8,
    metadata: {
      "review_role" => nil,
      "reviewer" => false
    }
  },
  {
    name: "Mason",
    slug: "mason",
    status: "active",
    agent_type: "specialist",
    title: "Marketing",
    description: "Runs marketing — brand voice, launch comms, social, funnels, copy. (Previously held Infrastructure; that surface now belongs to Steffon.)",
    avatar: "/agents/mason.png",
    position: 2,
    metadata: {
      "review_role" => nil,
      "reviewer" => false
    }
  }
]

# Each soul's status-line identity — glyph + tint — shown by bin/statusline when a
# session "acts as" this agent (a task persona) in place of its Pokémon. Read by
# Agent#emoji / Agent#status_color. Explicit colors so two souls never collide on
# the 8-bucket deterministic avatar palette (status_color falls back to it).
AGENT_EMOJI = {
  "alex" => "🧭", "avi" => "📋", "carl" => "🛠", "shannon" => "🎨",
  "jasper" => "🧪", "steffon" => "🚀", "turf-monster" => "🐲",
  "mack" => "📦", "mason" => "📣"
}.freeze
AGENT_COLOR = {
  "alex" => "#818CF8", "avi" => "#FB7185", "carl" => "#F97316", "shannon" => "#EC4899",
  "jasper" => "#9945FF", "steffon" => "#06B6D4", "turf-monster" => "#84CC16",
  "mack" => "#9CA3AF", "mason" => "#EF4444"
}.freeze

agents_data.each do |data|
  agent = Agent.find_or_initialize_by(slug: data[:slug])
  # Merge (not replace) metadata so any runtime-written keys survive a re-seed;
  # the keys this seed owns are still authoritatively set/overwritten.
  merged_metadata = (agent.metadata || {}).merge(data.fetch(:metadata, {}))
  merged_metadata["emoji"] = AGENT_EMOJI[data[:slug]] if AGENT_EMOJI.key?(data[:slug])
  merged_metadata["color"] = AGENT_COLOR[data[:slug]] if AGENT_COLOR.key?(data[:slug])
  agent.assign_attributes(
    name: data[:name],
    status: data[:status],
    agent_type: data[:agent_type],
    title: data[:title],
    description: data[:description],
    avatar: data[:avatar],
    position: data[:position],
    metadata: merged_metadata
  )
  agent.save! if agent.new_record? || agent.changed?
  puts "Agent: #{agent.name} (#{agent.agent_type}) — #{agent.title}"
end

# The `qa_owner` flag moved from Steffon to Avi in the 2026-07-22 reslot (Avi now
# runs qa-release + the QA deploy; Steffon moved to production-deploy). The metadata
# merge above only ADDS/overwrites the keys present in each soul's seed data, so an
# existing Steffon row keeps its stale `qa_owner` unless we strip it. Reconcile to a
# single owner: Avi holds `qa_owner`; clear the key from everyone else. Idempotent —
# a no-op once Avi is the sole holder.
Agent.where.not(slug: "avi").find_each do |agent|
  next unless agent.metadata.is_a?(Hash) && agent.metadata.key?("qa_owner")

  agent.update!(metadata: agent.metadata.except("qa_owner"))
  puts "Agent: cleared stale qa_owner from #{agent.slug} (it moved to avi)"
end

# The Documentation reviewer used to be a separate `alex-docs` persona; it's now
# folded into the single `alex` identity (orchestrator + the pool's docs seat).
# Retire the old row so the board roster and the reviewer pool show one Alex.
# Idempotent — a no-op once the row is gone. (Historical reviewer references in
# TaskEvent/Task metadata are rewritten alex-docs→alex by the matching migration.)
if (retired = Agent.find_by(slug: "alex-docs"))
  retired.destroy!
  puts "Agent: retired alex-docs (folded into alex)"
end
