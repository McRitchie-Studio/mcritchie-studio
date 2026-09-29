module Artists
  module Wikidata
    # Pure mapping from SPARQL JSON bindings to snapshot entries. No I/O.
    #
    # Wikidata now keeps many names under the "mul" (multilingual) language
    # rather than "en" (Jay-Z's label and aliases are mul only), so both count;
    # English wins where both exist.
    module Parser
      QID = %r{/entity/(Q\d+)\z}
      YEAR = /\A(-?\d{1,4})-\d\d-\d\dT/

      module_function

      def qid(value) = value.to_s[QID, 1]

      def year(value)
        match = value.to_s.match(YEAR)
        match && match[1].to_i
      end

      def qid_number(qid) = qid.to_s.delete_prefix("Q").to_i

      # core rows: x, en, mul, human, group, mb, discogs, spotify (ids repeat as
      # a cartesian product). alias rows: x, alias (with xml:lang).
      def artists(core_rows, alias_rows)
        items = core_rows.group_by { |row| qid(row.dig("x", "value")) }
        aliases = alias_rows.group_by { |row| qid(row.dig("x", "value")) }

        items.filter_map do |id, rows|
          next if id.nil?

          kind = kind_for(rows)
          name = first_value(rows, "en") || first_value(rows, "mul")
          next if kind.nil? || name.blank?

          {
            "wikidata_id" => id,
            "name" => name,
            "kind" => kind,
            "musicbrainz_id" => stable_id(rows, "mb"),
            "discogs_id" => stable_id(rows, "discogs"),
            "spotify_id" => stable_id(rows, "spotify"),
            "aliases" => alias_entries(aliases.fetch(id, []), name)
          }
        end.sort_by { |artist| qid_number(artist["wikidata_id"]) }
      end

      # rows: member, group, via ("part" = the group's has-part statement,
      # "member_of" = the member's member-of statement), start, end.
      # Per member/group pair, keep the direction whose statements carry more
      # dates (ties go to the group's own); each distinct stint in it survives.
      def memberships(rows)
        stints = rows.filter_map do |row|
          member = qid(row.dig("member", "value"))
          group = qid(row.dig("group", "value"))
          next if member.nil? || group.nil? || member == group

          { "member" => member, "group" => group, "via" => row.dig("via", "value"),
            "start_year" => year(row.dig("start", "value")), "end_year" => year(row.dig("end", "value")) }
        end

        stints.group_by { |s| [s["member"], s["group"]] }.flat_map do |_pair, pair_stints|
          by_via = pair_stints.group_by { |s| s["via"] }.transform_values { |l| l.map { |s| s.except("via") }.uniq }
          chosen = by_via.max_by { |via, list| [dated_fields(list), via == "part" ? 1 : 0] }.last
          dated = chosen.select { |s| s["start_year"] || s["end_year"] }
          next chosen.first(1) if dated.empty?

          # One stint per start year (the table's key); the widest one wins.
          dated.sort_by { |s| -(s["end_year"] || 9999) }.uniq { |s| s["start_year"] }
        end.sort_by { |s| [qid_number(s["member"]), qid_number(s["group"]), s["start_year"] || 0] }
      end

      def kind_for(rows)
        return "person" if rows.any? { |row| row.dig("human", "value") == "true" }
        return "group" if rows.any? { |row| row.dig("group", "value") == "true" }

        nil
      end

      def first_value(rows, key)
        rows.map { |row| row.dig(key, "value") }.compact.min
      end

      # Several values happen (Jay-Z has two Discogs ids). Pick one that does
      # not depend on row order: shortest, then lowest.
      def stable_id(rows, key)
        rows.map { |row| row.dig(key, "value") }.compact.uniq.min_by { |v| [v.length, v] }
      end

      def alias_entries(rows, name)
        entries = rows.filter_map do |row|
          alias_name = row.dig("alias", "value").to_s.strip
          next if alias_name.empty? || alias_name.casecmp?(name)

          { "name" => alias_name, "locale" => row.dig("alias", "xml:lang") || "en" }
        end
        entries.group_by { |e| e["name"] }.map { |_n, list| list.min_by { |e| e["locale"] == "en" ? 0 : 1 } }
               .sort_by { |e| [e["name"], e["locale"]] }
      end

      def dated_fields(list) = list.sum { |s| (s["start_year"] ? 1 : 0) + (s["end_year"] ? 1 : 0) }
    end
  end
end
