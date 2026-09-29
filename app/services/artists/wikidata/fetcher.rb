module Artists
  module Wikidata
    # Builds the CC0 artist snapshot from Wikidata. Run by hand
    # (`bin/rails artists:fetch_wikidata`), never on deploy; production loads
    # the committed file with artists:import_wikidata.
    #
    # Seed: rappers (occupation Q2252262) and musical groups whose genre falls
    # under hip hop, R&B or pop, each with an English Wikipedia article; plus
    # every person or group recorded as a member of one of those groups.
    class Fetcher
      BATCH = 200
      ENWIKI = "?article schema:about ?x ; schema:isPartOf <https://en.wikipedia.org/> ."
      GENRE_ROOTS = %w[Q11401 Q45981 Q37073].freeze # hip hop, R&B, pop
      MUSICAL_GROUP = "Q215380".freeze
      RAPPER = "Q2252262".freeze

      def initialize(client: Client.new, logger: nil)
        @client = client
        @logger = logger || ->(_msg) { }
      end

      def call
        rappers = ids("SELECT DISTINCT ?x WHERE { ?x wdt:P106 wd:#{RAPPER} . #{ENWIKI} }")
        log "rappers: #{rappers.size}"
        groups = ids(<<~SPARQL)
          SELECT DISTINCT ?x WHERE {
            VALUES ?root { #{GENRE_ROOTS.map { |q| "wd:#{q}" }.join(' ')} }
            ?genre wdt:P279* ?root .
            ?x wdt:P136 ?genre ; wdt:P31/wdt:P279* wd:#{MUSICAL_GROUP} .
            #{ENWIKI}
          }
        SPARQL
        log "groups: #{groups.size}"

        membership_rows = batched(groups, "memberships") { |values| @client.select(membership_query(values)) }
        memberships = Parser.memberships(membership_rows).select { |m| groups.include?(m["group"]) }

        seeds = {}
        rappers.each { |q| seeds[q] = "rapper" }
        groups.each { |q| seeds[q] ||= "group" }
        memberships.each { |m| seeds[m["member"]] ||= "member" }
        log "artists to describe: #{seeds.size}"

        artists = describe(seeds.keys).each { |a| a["seed"] = seeds[a["wikidata_id"]] }
        known = artists.to_set { |a| a["wikidata_id"] }
        memberships = memberships.select { |m| known.include?(m["member"]) && known.include?(m["group"]) }

        {
          "source" => "Wikidata (https://www.wikidata.org)",
          "license" => "CC0-1.0",
          "endpoint" => Client::ENDPOINT.to_s,
          "fetched_at" => Time.now.utc.iso8601,
          "artists" => artists,
          "memberships" => memberships
        }
      end

      # One artist per line so a refresh diffs cleanly.
      def self.write(snapshot, path)
        meta = snapshot.except("artists", "memberships")
        lines = meta.map { |k, v| "  #{k.to_json}: #{v.to_json}" }
        lines << "  \"artists\": [\n#{snapshot['artists'].map { |a| "    #{a.to_json}" }.join(",\n")}\n  ]"
        lines << "  \"memberships\": [\n#{snapshot['memberships'].map { |m| "    #{m.to_json}" }.join(",\n")}\n  ]"
        File.write(path, "{\n#{lines.join(",\n")}\n}\n")
      end

      private

      def log(message) = @logger.call(message)

      def ids(query)
        @client.select(query).filter_map { |row| Parser.qid(row.dig("x", "value")) }.uniq
                .sort_by { |q| Parser.qid_number(q) }
      end

      def describe(qids)
        core = batched(qids, "details") { |values| @client.select(core_query(values)) }
        aliases = batched(qids, "aliases") { |values| @client.select(alias_query(values)) }
        Parser.artists(core, aliases)
      end

      def batched(qids, label)
        slices = qids.each_slice(BATCH).to_a
        slices.each_with_index.flat_map do |slice, index|
          log "#{label} #{index + 1}/#{slices.size}" if (index % 10).zero?
          yield slice.map { |q| "wd:#{q}" }.join(" ")
        end
      end

      def core_query(values)
        <<~SPARQL
          SELECT ?x ?en ?mul ?human ?group ?mb ?discogs ?spotify WHERE {
            VALUES ?x { #{values} }
            OPTIONAL { ?x rdfs:label ?en FILTER(LANG(?en) = "en") }
            OPTIONAL { ?x rdfs:label ?mul FILTER(LANG(?mul) = "mul") }
            BIND(EXISTS { ?x wdt:P31 wd:Q5 } AS ?human)
            BIND(EXISTS { ?x wdt:P31/wdt:P279* wd:#{MUSICAL_GROUP} } AS ?group)
            OPTIONAL { ?x wdt:P434 ?mb }
            OPTIONAL { ?x wdt:P1953 ?discogs }
            OPTIONAL { ?x wdt:P1902 ?spotify }
          }
        SPARQL
      end

      def alias_query(values)
        <<~SPARQL
          SELECT ?x ?alias WHERE {
            VALUES ?x { #{values} }
            ?x skos:altLabel ?alias FILTER(LANG(?alias) IN ("en", "mul"))
          }
        SPARQL
      end

      # Both directions: the group's has part (P527) and each member's member of
      # (P463) pointing at the group, with start (P580) and end (P582) dates.
      def membership_query(values)
        <<~SPARQL
          SELECT ?member ?group ?via ?start ?end WHERE {
            VALUES ?group { #{values} }
            { ?group p:P527 ?st . ?st ps:P527 ?member . BIND("part" AS ?via) }
            UNION
            { ?member p:P463 ?st . ?st ps:P463 ?group . BIND("member_of" AS ?via) }
            OPTIONAL { ?st pq:P580 ?start }
            OPTIONAL { ?st pq:P582 ?end }
          }
        SPARQL
      end
    end
  end
end
