# Agent registry seed: one Agent row per soul in config/souls.yml, the roster's
# one source (Task::SOUL_ROSTER reads the same file).
#
# Idempotent upsert: safe to run on every deploy (release → QA/prod). The field
# meanings, including the metadata ReviewerSelector reads, are in that file's
# header.
#
# THE `alex` SOUL. It was `alex` until 2026-09-24, then `xan` until 2026-10-18,
# then `ray` (display Ritch) until 2026-10-25, when Alex McRitchie ruled the full
# rename back to `alex` (ritch-renamed-alex). It held the orchestrator seat until
# 2026-10-25, when Mason took it; `alex` is the client-facing persona now. The
# rename-in-place block below keeps the row's id and history;
# Task::SOUL_ALIASES reads `ray` and `xan` as `alex`.
agents_data = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls")

# `ray` / `xan` → `alex`, IN PLACE. A deployed database had the row and every
# stored soul-slug value repointed by data migrations (RenameAlexSoulToXan,
# RenameXanSoulToRay, RenameRaySoulToAlex). This is the seed's own idempotent half
# for a database those migrations never reached — a desk seeded from an older
# tree — so the upsert below FINDS `alex` instead of creating a second persona.
# Never `destroy` the old row: Agent has_many :activities dependent: :destroy, and
# the seat's history hangs off it. Runs before the roster loop on purpose. `xan`
# goes first: on a tree that predates 2026-10-18 it is the live row.
%w[xan ray].each do |retired_slug|
  legacy = Agent.find_by(slug: retired_slug)
  next unless legacy

  if Agent.exists?(slug: "alex")
    # Both present: the migration owns the children; only an empty shell may go.
    empty = legacy.activities.none? && legacy.usages.none? && legacy.skill_assignments.none? && legacy.tasks.none?
    if empty
      legacy.delete
      puts "Agent: retired the duplicate #{retired_slug} row (alex already seeded)"
    else
      puts "Agent: #{retired_slug} row still has children — db:migrate (RenameRaySoulToAlex) retires it"
    end
  else
    # rename_slug! moves every child with the row (the agent_slug keys cascade too).
    legacy.rename_slug!("alex")
    puts "Agent: renamed #{retired_slug} → alex in place (same row, history kept)"
  end
end

agents_data.each do |data|
  agent = Agent.find_or_initialize_by(slug: data.fetch("slug"))
  # Merge (not replace) metadata so any runtime-written keys survive a re-seed;
  # the keys this seed owns are still authoritatively set/overwritten.
  merged_metadata = (agent.metadata || {}).merge(data.fetch("metadata", nil) || {})
  merged_metadata["emoji"] = data["emoji"] if data["emoji"]
  merged_metadata["color"] = data["color"] if data["color"]
  agent.assign_attributes(
    name: data["name"],
    status: data["status"],
    agent_type: data["agent_type"],
    title: data["title"],
    description: data["description"],
    avatar: data["avatar"],
    position: data["position"],
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

# The Documentation reviewer used to be a separate `alex-docs` persona; it was
# folded into the single orchestrator identity (then `alex`, later `xan` and `ray`)
# — the orchestrator + the pool's docs seat, both Mason's since 2026-10-25. Retire the old row so the board roster and
# the reviewer pool show one orchestrator. Idempotent — a no-op once the row is
# gone. (Historical reviewer references in TaskEvent/Task metadata were rewritten
# alex-docs→alex by the matching migration, alex→xan by RenameAlexSoulToXan, and
# xan→ray by RenameXanSoulToRay, and ray→alex by RenameRaySoulToAlex.)
if (retired = Agent.find_by(slug: "alex-docs"))
  retired.destroy!
  puts "Agent: retired alex-docs (folded into the orchestrator seat)"
end
