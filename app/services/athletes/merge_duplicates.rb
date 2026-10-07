# Consolidates suffix-stripped duplicate Person records into the canonical
# (with-suffix) Person. The Spotrac importer used to strip "Jr.", "Sr.",
# "II", "III" etc. from last names while PFF / nflverse kept the suffix,
# producing two Person+Athlete records for the same player. The canonical
# one accumulated cross-ref IDs (gsis_id, pff_id, espn_id, otc_id, pfr_id);
# the duplicate accumulated contracts, depth chart entries, and headshots.
#
# This utility merges the duplicate into the canonical record through
# People::Merge. Conflicts (e.g. both have a Contract for the same team) drop
# the duplicate's row in favor of the canonical one.
#
# Defaults to dry-run. Pass dry_run: false to actually merge.
#
# Usage:
#   Athletes::MergeDuplicates.new(verbose: true).call            # dry run
#   Athletes::MergeDuplicates.new(dry_run: false).call           # commit
class Athletes::MergeDuplicates
  SUFFIXES = %w[jr sr ii iii iv v].freeze

  attr_reader :stats

  def initialize(dry_run: true, verbose: false)
    @dry_run = dry_run
    @verbose = verbose
    @stats = Hash.new(0)
  end

  def call
    pairs = find_duplicate_pairs
    puts "Found #{pairs.size} duplicate-Person pair(s) (dry_run=#{@dry_run})"

    pairs.each do |duplicate, canonical|
      vputs "  #{duplicate.slug.ljust(28)} → #{canonical.slug}"
      if @dry_run
        @stats[:would_merge] += 1
      else
        merge!(duplicate, canonical)
        @stats[:merged] += 1
      end
    end

    puts "\nstats: #{@stats.inspect}"
    @stats
  end

  # Returns Array of [duplicate_person, canonical_person]. Public so callers
  # can preview without invoking #call. Detects two patterns:
  #   1. Suffix-stripped: `will-anderson` ↔ `will-anderson-jr`
  #   2. Same-name distinct slugs: a Person with no IDs whose first+last
  #      matches another Person who DOES have IDs (e.g., punctuation/
  #      apostrophe variations that produced different parameterized slugs)
  def find_duplicate_pairs
    pairs = []
    seen_canonical_ids = Set.new

    Person.where(athlete: true).includes(:athlete_profile).find_each do |dup|
      ath = dup.athlete_profile
      next unless ath
      next if has_any_id?(ath)

      canonical = find_suffix_variant(dup) || find_same_name_with_ids(dup)
      next unless canonical
      next if seen_canonical_ids.include?(canonical.id)

      seen_canonical_ids << canonical.id
      pairs << [dup, canonical]
    end
    pairs
  end

  private

  def find_suffix_variant(dup)
    suffix_slugs = SUFFIXES.map { |s| "#{dup.slug}-#{s}" }
    Person.where(slug: suffix_slugs)
          .includes(:athlete_profile)
          .find { |c| has_any_id?(c.athlete_profile) }
  end

  def find_same_name_with_ids(dup)
    siblings = Person.where("LOWER(first_name) = LOWER(?) AND LOWER(last_name) = LOWER(?)",
                             dup.first_name, dup.last_name)
                     .where.not(id: dup.id)
                     .includes(:athlete_profile)
    siblings.find { |c| has_any_id?(c.athlete_profile) }
  end

  def has_any_id?(athlete)
    return false unless athlete
    [athlete.gsis_id, athlete.pff_id, athlete.espn_id, athlete.otc_id, athlete.pfr_id].any?(&:present?)
  end

  # The one person merge (People::Merge) moves every row the duplicate holds onto
  # the canonical record and destroys the duplicate, in one transaction. A pair it
  # refuses is counted and named, and the sweep goes on to the next pair.
  def merge!(duplicate, canonical)
    People::Merge.call!(keep: canonical, source: duplicate).each { |key, count| @stats[key] += count }
  rescue ActiveRecord::ActiveRecordError => e
    @stats[:refused] += 1
    puts "  refused #{duplicate.slug} → #{canonical.slug}: #{e.message}"
  end

  def vputs(msg)
    puts msg if @verbose
  end
end
