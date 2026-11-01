require "json"

# Layers Spotrac salary data on top of the identity records nflverse already
# seeded. Players are matched by otc_id (Spotrac/OverTheCap's player ID, which
# nflverse provides as a cross-reference column) where available, falling back
# to name matching for entries that don't yet have otc_id.
#
# For each Spotrac entry: find or create the active Contract for the player on
# Spotrac's team, set annual_value_cents and expires_at (end_year → March 15
# of that year, when the NFL league year ends). Athlete.team_slug is updated
# in line with the team_slug-on-contract-update rule.
#
# Idempotent: re-running on unchanged JSON is a no-op. Run order in the
# rebuild pipeline puts this AFTER nfl:players_seed (so otc_ids are already on
# Athletes) and BEFORE espn:scrape_depth_charts (so ESPN's depth-chart-driven
# Contracts inherit and refine what Spotrac just placed).
#
# Usage:
#   Spotrac::SyncContracts.new.call
#   Spotrac::SyncContracts.new(json_path: "/tmp/contracts.json", verbose: true).call
#
# Without a json_path it reads SNAPSHOT from R2 (SeedSnapshot) and skips when
# there is none to read.
class Spotrac::SyncContracts
  SNAPSHOT = "spotrac_contracts_2025.json".freeze

  attr_reader :stats

  def initialize(json_path: nil, verbose: false, entries: nil)
    @json_path = json_path
    @verbose = verbose
    @entries = entries
    @stats = Hash.new(0)
  end

  def call
    entries = load_entries
    return @stats unless entries

    puts "Spotrac sync: #{entries.size} entries"
    entries.each do |data|
      ingest_entry(data)
    rescue StandardError => e
      @stats[:failed] += 1
      vputs "  [!] #{data[:first_name]} #{data[:last_name]}: #{e.message}"
    end

    puts "\nSpotrac sync: #{@stats.inspect}"
    @stats
  end

  # Public so tests (and callers re-using a parsed JSON) can drive a single entry.
  def ingest_entry(data)
    position = PositionConcern.normalize_position(data[:position], source: :spotrac)
    otc_id = data[:otc_id].to_s.strip.presence

    person, athlete = resolve_athlete(data, otc_id, position)
    return nil unless person && athlete

    sync_contract(person, data, position)
    sync_team_slug(athlete, data[:team_slug])
    [person, athlete]
  end

  private

  def load_entries
    return @entries if @entries

    raw = @json_path ? read_file : read_snapshot
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def read_file
    return File.read(@json_path) if File.exist?(@json_path)

    puts "[!] Spotrac JSON not found at #{@json_path}"
    nil
  end

  def read_snapshot
    SeedSnapshot.read(SNAPSHOT).tap do |raw|
      puts "Spotrac: no #{SeedSnapshot.key(SNAPSHOT)} to read, skipping" unless raw
    end
  end

  # Match by otc_id first (canonical anchor when available), fall back to smart
  # name matching, finally create from Spotrac data if neither path resolves.
  def resolve_athlete(data, otc_id, position)
    if otc_id
      ath = Athlete.find_by(otc_id: otc_id)
      return [ath.person, ath] if ath
    end

    person = Person.find_or_create_by_name!(data[:first_name], data[:last_name], athlete: true)
    @stats[:people_created] += 1 if person.previously_new_record?

    athlete = person.athlete_profile
    if athlete.nil?
      athlete = Athlete.create!(person_slug: person.slug, sport: "football",
                                position: position, otc_id: otc_id)
      @stats[:athletes_created] += 1
    elsif otc_id && athlete.otc_id.blank?
      athlete.update!(otc_id: otc_id)
      @stats[:otc_ids_backfilled] += 1
    end

    [person, athlete]
  end

  def sync_contract(person, data, position)
    expires_at = data[:end_year].to_i > 0 ? Date.new(data[:end_year], 3, 15) : nil
    contract = Contract.find_or_initialize_by(person_slug: person.slug, team_slug: data[:team_slug])

    if contract.new_record?
      contract.assign_attributes(
        contract_type:       "active",
        position:            position,
        expires_at:          expires_at,
        annual_value_cents:  data[:annual_value_cents]
      )
      contract.save!
      @stats[:contracts_created] += 1
      return
    end

    changed = false
    if contract.annual_value_cents != data[:annual_value_cents]
      contract.annual_value_cents = data[:annual_value_cents]
      changed = true
    end
    if expires_at && contract.expires_at != expires_at
      contract.expires_at = expires_at
      changed = true
    end
    if contract.position.blank? && position.present?
      contract.position = position
      changed = true
    end

    if changed
      contract.save!
      @stats[:contracts_updated] += 1
    else
      @stats[:contracts_unchanged] += 1
    end
  end

  def sync_team_slug(athlete, team_slug)
    return if team_slug.blank? || athlete.team_slug == team_slug
    athlete.update!(team_slug: team_slug)
    @stats[:team_slug_updates] += 1
  end

  def vputs(msg)
    puts msg if @verbose
  end
end
