# Read model for the public Pokédex page. It keeps the controller/view focused on
# presentation while this object owns the cross-table shape: spawned session
# mascots, shiny counts, and recent mascot-bearing actions.
class PokemonPokedex
  RecentAction = Struct.new(:action, :pokemon, keyword_init: true)
  Spawn = Struct.new(:pokemon, :created_at, :task, :shiny, keyword_init: true)

  attr_reader :recent_limit

  def initialize(recent_limit: 20)
    @recent_limit = recent_limit
  end

  def total_pokemon
    Pokemon.count
  end

  def summoned_pokemon
    return 0 if pokemon_slugs.empty?

    SessionMascot.where(mascot_slug: pokemon_slugs).count
  end

  def shiny_pokemon
    return 0 if pokemon_slugs.empty?

    SessionMascot.where(mascot_slug: pokemon_slugs, shiny: true).count
  end

  def latest_spawn
    @latest_spawn ||= latest_session_spawn || latest_task_spawn
  end

  def latest_shiny_spawn
    @latest_shiny_spawn ||= latest_session_spawn(shiny: true) || latest_task_spawn(shiny: true)
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

  def latest_session_spawn(shiny: nil)
    mascots = SessionMascot.where(mascot_slug: pokemon_slugs)
    mascots = mascots.where(shiny: shiny) unless shiny.nil?
    mascot = mascots.order(created_at: :desc, id: :desc).first
    return nil unless mascot

    pokemon = pokemon_by_slug[mascot.mascot_slug]
    return nil unless pokemon

    Spawn.new(
      pokemon: pokemon,
      created_at: mascot.created_at,
      task: task_for_session(mascot.session_id),
      shiny: mascot.shiny?
    )
  end

  def latest_task_spawn(shiny: nil)
    tasks = Task.where("NULLIF(metadata->'devops'->>'mascot', '') IS NOT NULL")
    tasks = tasks.where("metadata->'devops'->>'mascot_shiny' = 'true'") if shiny
    task = tasks.order(created_at: :desc, id: :desc).first
    return nil unless task

    pokemon = pokemon_by_slug[task.devops_field("mascot")]
    return nil unless pokemon

    Spawn.new(
      pokemon: pokemon,
      created_at: task.created_at,
      task: task,
      shiny: task.mascot_shiny?
    )
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
