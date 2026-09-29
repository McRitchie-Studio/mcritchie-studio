module Artists
  module Wikidata
    # Loads the committed Wikidata snapshot into artists, aliases and
    # memberships. No network. Idempotent: rows are matched by wikidata_id
    # (artists), name + locale (aliases) and member + group + start year
    # (memberships), and only new or changed rows are written, so a re-run
    # writes nothing.
    #
    # Additive: a row the snapshot no longer carries is left alone. Slugs are
    # never rewritten once set, because other records will point at them.
    class SnapshotImporter
      DEFAULT_PATH = Rails.root.join("db/seeds/data/artists_wikidata.json")
      FIELDS = %w[name kind musicbrainz_id discogs_id spotify_id].freeze

      def initialize(source = DEFAULT_PATH)
        @data = source.is_a?(Hash) ? source : JSON.parse(File.read(source))
      end

      def call
        Artist.transaction do
          slugs, artists = import_artists
          aliases = import_aliases(slugs)
          memberships, skipped = import_memberships(slugs)
          { artists: artists, aliases: aliases, memberships: memberships, skipped_memberships: skipped }
        end
      end

      private

      def entries = @data.fetch("artists").sort_by { |a| Parser.qid_number(a["wikidata_id"]) }

      # Returns [qid => slug, rows written].
      def import_artists
        existing = Artist.where.not(wikidata_id: nil).pluck(:wikidata_id, :slug, *FIELDS)
                         .to_h { |qid, slug, *values| [qid, [slug, FIELDS.zip(values).to_h]] }
        taken = Set.new(Artist.pluck(:slug))
        slugs = existing.transform_values(&:first)
        inserts = []
        written = 0

        entries.each do |entry|
          attrs = FIELDS.to_h { |field| [field, entry[field]] }
          qid = entry.fetch("wikidata_id")
          if (slug, current = existing[qid])
            next if current == attrs

            Artist.where(wikidata_id: qid).update_all(attrs.merge("updated_at" => Time.current))
            written += 1
          else
            slug = unique_slug(attrs["name"], qid, taken)
            taken << slug
            slugs[qid] = slug
            inserts << attrs.merge("wikidata_id" => qid, "slug" => slug, "sort_name" => Artist.sort_name_for(attrs["name"]))
          end
        end

        inserts.each_slice(1000) { |batch| Artist.insert_all!(batch) }
        [slugs, written + inserts.size]
      end

      # The lower Wikidata id takes the bare slug; a later namesake gets its id.
      def unique_slug(name, qid, taken)
        base = name.to_s.parameterize.presence || qid.downcase
        taken.include?(base) ? "#{base}-#{qid.downcase}" : base
      end

      def import_aliases(slugs)
        existing = Set.new(ArtistAlias.pluck(:artist_slug, :name, :locale))
        rows = entries.flat_map do |entry|
          slug = slugs.fetch(entry["wikidata_id"])
          Array(entry["aliases"]).map { |a| [slug, a.fetch("name"), a.fetch("locale")] }
        end
        rows = rows.uniq.reject { |row| existing.include?(row) }
        rows.each_slice(1000) do |batch|
          ArtistAlias.insert_all!(batch.map { |slug, name, locale| { artist_slug: slug, name: name, locale: locale } })
        end
        rows.size
      end

      # Returns [rows written, rows skipped because an end is not in the snapshot].
      def import_memberships(slugs)
        existing = ArtistMembership.pluck(:member_artist_slug, :group_artist_slug, :start_year, :end_year)
                                   .to_h { |member, group, start, finish| [[member, group, start], finish] }
        inserts = []
        written = 0
        skipped = 0

        @data.fetch("memberships").each do |m|
          member = slugs[m["member"]]
          group = slugs[m["group"]]
          next skipped += 1 if member.nil? || group.nil?

          key = [member, group, m["start_year"]]
          if existing.key?(key)
            next if existing[key] == m["end_year"]

            ArtistMembership.where(member_artist_slug: member, group_artist_slug: group, start_year: m["start_year"])
                            .update_all(end_year: m["end_year"], updated_at: Time.current)
            written += 1
          else
            existing[key] = m["end_year"]
            inserts << { member_artist_slug: member, group_artist_slug: group,
                         start_year: m["start_year"], end_year: m["end_year"] }
          end
        end

        inserts.each_slice(1000) { |batch| ArtistMembership.insert_all!(batch) }
        [written + inserts.size, skipped]
      end
    end
  end
end
