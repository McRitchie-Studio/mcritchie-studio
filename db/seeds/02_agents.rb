# Agent registry seed.
#
# Idempotent upsert: safe to run on every deploy (release → QA/prod). Each soul
# carries the Deploy-flow redesign roles + the metadata the `ReviewerSelector`
# reads when Avi delegates a review (see
# docs/agents/system/devops-cycle-design.md §1.2):
#
#   metadata["reviewer"]       — true if in the senior review pool
#   metadata["review_role"]    — "delegator" | "reviewer" | "orchestrator"
#   metadata["domains"]        — areas/repos this soul reviews (domain-fit input)
#   metadata["review_weight"]  — NUMERIC review weight (higher = takes the heavy,
#                                deep-review seat when a pair ties on domain fit).
#                                Stored as a number, NOT the "heavy"/"light" label
#                                a bare String#to_f would silently zero (see
#                                ReviewerSelector::WEIGHT_LABELS). All five seniors
#                                are heavy-capable, so they share the heavy weight;
#                                within a pair the seat falls to fit then the
#                                logged roll. ReviewerSelector::WEIGHT_LABELS maps
#                                heavy->2.0 / light->1.0 for any legacy label rows.
#
# Pool {Shannon=UI · Carl=backend · Jasper=Web3 · Steffon=DevOps/Platform ·
# Alex=Documentation}. Avi is the delegator (selects 1 heavy + 1 light), not a
# pool member; Steffon is `qa_owner` and must never review a PR he will then QA.
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
    description: "Product Owner and Deploy-flow review delegator. Refines tickets, sets po_size, confirms product-acceptance, then selects the two senior reviewers (domain fit + a logged random tiebreak; 1 heavy + 1 light). Owns the ship gate — full e2e on the frozen ship SHA, then the operator gate before prod.",
    avatar: "/agents/avi.png",
    position: 3,
    metadata: {
      "review_role" => "delegator",
      "reviewer" => false,
      "ship_gate" => true,
      "responsibilities" => ["product-acceptance", "reviewer-selection", "ship-gate"]
    }
  },
  {
    name: "Carl",
    slug: "carl",
    status: "active",
    agent_type: "specialist",
    title: "Dev Backend Expert",
    description: "Crack Rails dev. Owns controllers, models, migrations, background jobs, ActiveRecord performance, and the studio-engine internals. Senior reviewer for backend PRs in the Deploy-flow review pool.",
    avatar: "/agents/carl.png",
    position: 4,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
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
    description: "Platform Engineer (QA + Infrastructure). Owns the QA test tier (integration + an e2e smoke) and the QA deploy of origin/release, plus Heroku deploys, env vars, CI, observability, and the recovery protocol. Senior reviewer for DevOps/Platform PRs — but never reviews a PR he will then QA (no self-gating).",
    avatar: "/agents/steffon.png",
    position: 7,
    metadata: {
      "review_role" => "reviewer",
      "reviewer" => true,
      "domains" => ["devops", "release", "infrastructure", "ci", "observability", "heroku"],
      "review_weight" => 2.0,
      "qa_owner" => true
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

agents_data.each do |data|
  agent = Agent.find_or_initialize_by(slug: data[:slug])
  # Merge (not replace) metadata so any runtime-written keys survive a re-seed;
  # the keys this seed owns are still authoritatively set/overwritten.
  merged_metadata = (agent.metadata || {}).merge(data.fetch(:metadata, {}))
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

# The Documentation reviewer used to be a separate `alex-docs` persona; it's now
# folded into the single `alex` identity (orchestrator + the pool's docs seat).
# Retire the old row so the board roster and the reviewer pool show one Alex.
# Idempotent — a no-op once the row is gone. (Historical reviewer references in
# TaskEvent/Task metadata are rewritten alex-docs→alex by the matching migration.)
if (retired = Agent.find_by(slug: "alex-docs"))
  retired.destroy!
  puts "Agent: retired alex-docs (folded into alex)"
end
