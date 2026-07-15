# Read model for the public Pokédex page. It keeps the controller/view focused on
# presentation while this object owns the cross-table shape behind the two cards:
# SEEN and CAUGHT, each as a count of DISTINCT species plus its newest member.
#
# SEEN is a sighting: a spawn (a SessionMascot row) or an evolution (a TaskEvent
# mascot snapshot — how a task's mascot climbs its line at the submitted/reviewed
# gates, the only place evolved forms are recorded). The newest-seen card shows the
# species whose FIRST sighting is most recent, so re-spawning or re-evolving a
# species already seen never re-bumps it; only a genuinely new species does.
#
# CAUGHT is a ship: a task reaching `shipped`, which catches the mascot it shipped
# (its final form) AND that form's pre-evolutions — never its siblings. The mascot
# is read from the shipped event's snapshot, falling back to the task's own
# devops.mascot for the older rows that carry no snapshot (see #all_catch_appearances).
#
# THE INVARIANT: Seen >= Caught, always. A catch is itself an encounter, so every
# caught species is folded back into the sightings (see #first_sightings). Dex idiom
# is that caught is a SUBSET of seen — you cannot catch what you never encountered —
# and these two numbers sit side by side on a public card, so the guarantee has to be
# structural, not incidental.
class PokemonPokedex
  RecentAction = Struct.new(:action, :pokemon, keyword_init: true)

  # One species' FIRST sighting. first_seen_at is the earliest moment it was seen;
  # task + shiny describe that first sighting (the task it was spawned/evolved in,
  # and whether that first appearance came up shiny).
  Sighting = Struct.new(:pokemon, :first_seen_at, :task, :shiny, keyword_init: true)

  # One raw appearance of a mascot, before we reduce to the earliest per species.
  # task_slug (evolutions) / session_id (spawns) let us resolve the task lazily,
  # only for the single winning sighting.
  Appearance = Struct.new(:slug, :at, :shiny, :session_id, :task_slug, keyword_init: true)

  # One cell of the collection grid: a species plus the COLLECTION STATE the grid
  # renders it in. The three states are exclusive and ordered by the dex invariant
  # (caught ⊆ seen), so :caught is decided before :seen. `evolutions` are the cells
  # this form evolves into — themselves Entries, so each evolution circle is drawn in
  # its OWN state and an unseen form never spoils itself through its own line.
  Entry = Struct.new(:pokemon, :state, :shiny_seen, :evolutions, keyword_init: true) do
    def caught?
      state == :caught
    end

    def unseen?
      state == :unseen
    end

    # Revealed = encountered at all. The grid only lets a revealed species flip to
    # its shiny art; flipping a silhouette would just redraw the same silhouette.
    def revealed?
      !unseen?
    end
  end

  attr_reader :recent_limit

  def initialize(recent_limit: 20)
    @recent_limit = recent_limit
  end

  def total_pokemon
    Pokemon.count
  end

  # How many DISTINCT species have been SEEN — spawned or evolved into — no matter
  # how many times. shiny:true counts only species whose sighting came up shiny.
  def seen_pokemon(shiny: false)
    first_sightings(shiny: shiny).size
  end

  # How many DISTINCT species have been CAUGHT: every shipped task's mascot plus its
  # pre-evolutions. shiny:true counts only species caught via a shiny ship.
  def caught_pokemon(shiny: false)
    caught_slugs(shiny: shiny).size
  end

  # THE COLLECTION GRID: every seeded species in dex order, each carrying the state
  # the grid draws it in — :caught (shipped, full color), :seen (encountered, dimmed)
  # or :unseen (silhouette) — plus whether it has ever been sighted shiny.
  #
  # It reads ONLY the memos the two cards above already built: the in-memory dex, the
  # first-sighting map, and the caught set. So rendering all 251 cells adds ZERO
  # queries to a public pageview — the whole grid is a re-projection of numbers the
  # page had already paid for.
  def dex_entries
    @dex_entries ||= begin
      shiny_seen = seen_slugs(shiny: true)
      entries = all_pokemon.map do |pokemon|
        Entry.new(pokemon: pokemon, state: entry_state(pokemon.slug),
                  shiny_seen: shiny_seen.include?(pokemon.slug), evolutions: [])
      end

      # Link each entry to the ENTRIES it evolves into, in a second pass over the map
      # just built. Pokemon#evolutions would query per cell — 251 of them on a public
      # page — and the evolution circles need each next form's state anyway.
      by_slug = entries.index_by { |entry| entry.pokemon.slug }
      entries.each do |entry|
        entry.evolutions = Array(entry.pokemon.evolution).filter_map { |slug| by_slug[slug] }
      end
    end
  end

  # Every seeded species, dex order. Sorted in Ruby off the map the cards already
  # loaded rather than re-querying with an ORDER BY — see #dex_entries.
  def all_pokemon
    @all_pokemon ||= pokemon_by_slug.values.sort_by(&:dex)
  end

  # The SEEN species as a Set of slugs — the same first-sighting map #seen_pokemon
  # counts, exposed for the grid instead of recomputed.
  def seen_slugs(shiny: false)
    (@seen_slugs ||= {})[shiny] ||= first_sightings(shiny: shiny).keys.to_set
  end

  # The CAUGHT species as a Set of slugs: each shipped mascot PLUS its pre-evolutions.
  # A task ships its FINAL form, so catching it also catches everything earlier in the
  # line. Only seeded Pokémon count. This is what #caught_pokemon counts.
  def caught_slugs(shiny: false)
    (@caught_slugs ||= {})[shiny] ||= catch_appearances(shiny: shiny).each_with_object(Set.new) do |appearance, set|
      lineage_up_to(appearance.slug).each { |slug| set << slug if pokemon_by_slug.key?(slug) }
    end
  end

  # The newest UNIQUE Pokémon — the species whose earliest sighting is the most
  # recent, across spawns and evolutions.
  def newest_unique
    @newest_unique ||= newest_first_sighting(first_sightings)
  end

  # Same, restricted to shiny sightings — the species whose first SHINY appearance
  # is the most recent.
  def newest_unique_shiny
    @newest_unique_shiny ||= newest_first_sighting(first_sightings(shiny: true))
  end

  # The newest CAUGHT Pokémon — the mascot of the most recently shipped task (the
  # final evolution the task climbed to). shiny:true tracks the newest shiny ship.
  def newest_caught
    @newest_caught ||= newest_catch_sighting(catch_appearances)
  end

  def newest_caught_shiny
    @newest_caught_shiny ||= newest_catch_sighting(catch_appearances(shiny: true))
  end

  def recent_actions
    return [] if pokemon_slugs.empty?

    AgentAction.where(mascot: pokemon_slugs)
               .includes(:task)
               .order(occurred_at: :desc, id: :desc)
               .limit(recent_limit)
               .map { |action| RecentAction.new(action: action, pokemon: pokemon_by_slug[action.mascot]) }
               .select(&:pokemon)
  end

  private

  # One species' collection state. The order is the dex invariant, not a preference:
  # caught is a SUBSET of seen (a catch is an encounter), so every caught species is
  # also in `seen_slugs` and must be claimed by :caught first or it would render as
  # merely seen.
  def entry_state(slug)
    if caught_slugs.include?(slug)
      :caught
    elsif seen_slugs.include?(slug)
      :seen
    else
      :unseen
    end
  end

  # Build the featured Sighting from the earliest-per-species map: pick the species
  # whose first sighting is the most recent, then resolve its Pokémon + task.
  def newest_first_sighting(earliest_by_slug)
    chosen = earliest_by_slug.values.max_by(&:at)
    return nil unless chosen

    pokemon = pokemon_by_slug[chosen.slug]
    return nil unless pokemon

    Sighting.new(
      pokemon: pokemon,
      first_seen_at: chosen.at,
      task: sighting_task(chosen),
      shiny: chosen.shiny
    )
  end

  # Build the featured CATCH Sighting: the most recent shipped-task mascot, resolved
  # to its Pokémon + task. first_seen_at carries the ship (catch) time.
  #
  # The seeded-Pokémon guard runs BEFORE picking the newest, not after: a ship whose
  # mascot snapshot is a persona (not a seeded Pokémon) must be skipped over, not
  # allowed to win the max and blank the card out to "None caught yet" while real
  # catches sit behind it.
  def newest_catch_sighting(appearances)
    chosen = appearances.select { |appearance| pokemon_by_slug.key?(appearance.slug) }.max_by(&:at)
    return nil unless chosen

    Sighting.new(pokemon: pokemon_by_slug[chosen.slug], first_seen_at: chosen.at,
                 task: sighting_task(chosen), shiny: chosen.shiny)
  end

  # slug => the EARLIEST Appearance of that species. shiny:true keeps only shiny
  # appearances (a species' first shiny moment). Only seeded Pokémon count, so a
  # persona/agent mascot on a TaskEvent is dropped. Memoized per shiny flag — the
  # seen count and the newest-unique card both read it.
  #
  # CATCHES COUNT AS SIGHTINGS. A catch IS an encounter, so every slug the lineage
  # walk sweeps into Caught is also credited here. That makes Seen >= Caught
  # STRUCTURALLY rather than by luck: in dex idiom you cannot catch what you have
  # never encountered, and without this a card could render "Seen 1 · Caught 3" —
  # a pre-evolution caught through its final form but never itself spawned.
  def first_sightings(shiny: false)
    (@first_sightings ||= {})[shiny] ||= begin
      earliest = {}
      all = spawn_appearances(shiny: shiny) +
            evolution_appearances(shiny: shiny) +
            catch_sightings(shiny: shiny)
      all.each do |appearance|
        next unless pokemon_by_slug.key?(appearance.slug)

        current = earliest[appearance.slug]
        earliest[appearance.slug] = appearance if current.nil? || appearance.at < current.at
      end
      earliest
    end
  end

  # Each catch, exploded across the whole line it caught: the shipped form AND its
  # pre-evolutions, each sighted at the ship time. This is what keeps every caught
  # species inside Seen. It also gives "Newest Seen" a sensible entry for a species
  # that was caught through its final form but never spawned on its own.
  def catch_sightings(shiny: false)
    (@catch_sightings ||= {})[shiny] ||= catch_appearances(shiny: shiny).flat_map do |catch_at|
      lineage_up_to(catch_at.slug).map do |slug|
        Appearance.new(slug: slug, at: catch_at.at, shiny: catch_at.shiny,
                       session_id: nil, task_slug: catch_at.task_slug)
      end
    end
  end

  # A catch is a task reaching `shipped`. shiny:true keeps only ships whose mascot
  # came up shiny.
  def catch_appearances(shiny: false)
    (@catch_appearances ||= {})[shiny] ||= shiny ? all_catch_appearances.select(&:shiny) : all_catch_appearances
  end

  # Every shipped transition, resolved to the mascot it caught.
  #
  # write_stage_event snapshots the mascot onto the transition, and that snapshot
  # WINS when present — it froze the form the task actually shipped. But older rows
  # carry no snapshot (TaskEvent#mascot_snapshot documents exactly this: "readers
  # should fall back to the task's current mascot when needed"), and most shipped
  # rows on the board are older rows. The task keeps devops.mascot forever —
  # archiving never clears it — so it is a sound fallback, and without it the Caught
  # number would be derived from only the minority of ships that carry a snapshot.
  #
  # Rows the task_events:backfill task synthesized carry neither a snapshot nor, in
  # some cases, a task mascot; those are genuinely unrecoverable. They drop out
  # rather than 500 a public page, but the count is LOGGED — a silent drop would make
  # any future drift in the Caught number undiagnosable.
  def all_catch_appearances
    @all_catch_appearances ||= begin
      rows = TaskEvent.transitions.where(to_stage: "shipped").pluck(
        Arel.sql("metadata->'mascot'->>'slug'"),
        :occurred_at,
        Arel.sql("metadata->'mascot'->>'shiny'"),
        :task_slug
      )
      unsnapshotted = rows.filter_map { |slug, _at, _shiny, task_slug| task_slug if slug.blank? }
      fallback = task_mascots(unsnapshotted)
      dropped = 0

      appearances = rows.filter_map do |slug, at, shiny_flag, task_slug|
        if slug.present?
          Appearance.new(slug: slug, at: at, shiny: Task.shiny_value?(shiny_flag),
                         session_id: nil, task_slug: task_slug)
        elsif (mascot = fallback[task_slug])
          Appearance.new(slug: mascot.first, at: at, shiny: mascot.last,
                         session_id: nil, task_slug: task_slug)
        else
          dropped += 1
          nil
        end
      end

      if dropped.positive?
        Rails.logger.info(
          "[pokedex] Caught excludes #{dropped} shipped event(s): no mascot snapshot and no recoverable task mascot"
        )
      end
      appearances
    end
  end

  # task_slug => [mascot slug, shiny] for the shipped rows carrying no snapshot.
  # One query for the whole fallback set, so it never becomes a per-row lookup.
  #
  # devops.mascot_shiny is the LEAST controlled shiny representation we read (event
  # snapshots are written as a literal boolean; this one has held true, "true", and
  # "1"), so it must go through the canonical Task.shiny_value? — a raw == "true"
  # would silently undercount shiny Caught.
  def task_mascots(task_slugs)
    return {} if task_slugs.empty?

    Task.where(slug: task_slugs.uniq)
        .pluck(:slug, Arel.sql("metadata->'devops'->>'mascot'"), Arel.sql("metadata->'devops'->>'mascot_shiny'"))
        .each_with_object({}) do |(task_slug, mascot, shiny_flag), map|
          map[task_slug] = [mascot, Task.shiny_value?(shiny_flag)] if mascot.present?
        end
  end

  # A caught slug plus its PRE-EVOLUTIONS: the ancestor path base -> slug.
  #
  # It walks the actual evolution links — it must NOT slice a flattened family walk,
  # which sweeps in SIBLINGS: Eevee branches five ways, so catching Umbreon yields
  # {eevee, umbreon}, never the other four Eeveelutions.
  #
  # The walk reads entirely off the in-memory dex (pokemon_by_slug already loads all
  # 251 rows, `base` and `evolution` included), so a public pageview costs ZERO extra
  # queries no matter how many species are caught.
  def lineage_up_to(slug)
    (@lineage ||= {})[slug] ||= begin
      if pokemon_by_slug.key?(slug)
        path = [slug]
        cursor = slug
        # Guard the walk by dex size so malformed data can never loop forever.
        while (parent = parent_slugs[cursor]) && path.size <= pokemon_by_slug.size
          path.unshift(parent)
          cursor = parent
        end
        path
      else
        [slug]
      end
    end
  end

  # child slug => the slug it evolves FROM, built ONCE for the whole dex off the
  # in-memory memo. Each Pokémon's `evolution` list names the forms it evolves into,
  # so inverting those lists gives every form's single pre-evolution.
  def parent_slugs
    @parent_slugs ||= pokemon_by_slug.each_value.with_object({}) do |pokemon, map|
      Array(pokemon.evolution).each { |child| map[child] = pokemon.slug }
    end
  end

  # Spawn sightings: every session mascot draw.
  def spawn_appearances(shiny:)
    scope = SessionMascot.where(mascot_slug: pokemon_slugs)
    scope = scope.where(shiny: true) if shiny
    scope.pluck(:mascot_slug, :created_at, :shiny, :session_id).map do |slug, at, shiny_flag, session_id|
      Appearance.new(slug: slug, at: at, shiny: shiny_flag, session_id: session_id, task_slug: nil)
    end
  end

  # Evolution sightings (and every other build-lane transition): TaskEvents snapshot
  # the mascot that owned the event, so evolved forms — which never land in
  # SessionMascot — surface here. metadata.mascot.shiny is stored only when true.
  def evolution_appearances(shiny:)
    scope = TaskEvent.where("metadata->'mascot'->>'slug' IS NOT NULL")
    scope = scope.where("metadata->'mascot'->>'shiny' = 'true'") if shiny
    slug_sql  = Arel.sql("metadata->'mascot'->>'slug'")
    shiny_sql = Arel.sql("metadata->'mascot'->>'shiny'")
    scope.pluck(slug_sql, :occurred_at, shiny_sql, :task_slug).map do |slug, at, shiny_flag, task_slug|
      Appearance.new(slug: slug, at: at, shiny: Task.shiny_value?(shiny_flag),
                     session_id: nil, task_slug: task_slug)
    end
  end

  def sighting_task(appearance)
    if appearance.task_slug.present?
      Task.find_by(slug: appearance.task_slug)
    elsif appearance.session_id.present?
      task_for_session(appearance.session_id)
    end
  end

  def task_for_session(session_id)
    action_task_for_session(session_id) || metadata_task_for_session(session_id)
  end

  def action_task_for_session(session_id)
    AgentAction.where(session_id: session_id)
               .where.not(task_slug: [nil, ""])
               .includes(:task)
               .order(occurred_at: :desc, id: :desc)
               .find(&:task)
               &.task
  end

  def metadata_task_for_session(session_id)
    Task.where("metadata->'devops'->>'session_id' = ?", session_id)
        .order(created_at: :desc, id: :desc)
        .first
  end

  def pokemon_by_slug
    @pokemon_by_slug ||= Pokemon.where(slug: pokemon_slugs).index_by(&:slug)
  end

  def pokemon_slugs
    @pokemon_slugs ||= Pokemon.pluck(:slug)
  end
end
