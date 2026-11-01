require "net/http"
require "nokogiri"
require "json"

namespace :spotrac do
  desc "Scrape NFL contract data from Spotrac for all 32 teams"
  task scrape: :environment do
    # Spotrac URL codes (lowercase) → team slug mapping
    # Built from Team.nfl short_name values
    team_map = Team.nfl.pluck(:short_name, :slug).to_h { |sn, slug| [sn.downcase, slug] }

    spotrac_codes = %w[
      ari atl bal buf car chi cin cle dal den det gb hou ind jax kc
      lv lac lar mia min ne no nyg nyj phi pit sf sea tb ten was
    ]

    contracts = []
    errors = []

    spotrac_codes.each_with_index do |code, idx|
      team_slug = team_map[code]
      unless team_slug
        puts "SKIP: No team mapping for Spotrac code '#{code}'"
        errors << { code: code, error: "No team mapping" }
        next
      end

      url = "https://www.spotrac.com/nfl/contracts/_/team/#{code}"
      puts "[#{idx + 1}/32] Fetching #{code.upcase} (#{team_slug})..."

      begin
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 15

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        request["Accept"] = "text/html,application/xhtml+xml"

        response = http.request(request)

        unless response.code == "200"
          puts "  ERROR: HTTP #{response.code}"
          errors << { code: code, team_slug: team_slug, error: "HTTP #{response.code}" }
          sleep 2
          next
        end

        doc = Nokogiri::HTML(response.body)
        table = doc.at_css("table#table")

        unless table
          puts "  ERROR: No table found"
          errors << { code: code, team_slug: team_slug, error: "No table found" }
          sleep 2
          next
        end

        rows = table.css("tbody tr")
        team_count = 0

        rows.each do |row|
          cells = row.css("td")
          next if cells.size < 9

          name = cells[0].text.strip
          position = cells[1].text.strip
          start_year = cells[4].text.strip
          end_year = cells[5].text.strip
          years = cells[6].text.strip
          total_value = cells[7].text.strip
          average_salary = cells[8].text.strip
          guaranteed = cells[10]&.text&.strip

          # Parse dollar amounts → cents
          average_cents = parse_dollars(average_salary)
          total_cents = parse_dollars(total_value)
          guaranteed_cents = parse_dollars(guaranteed)

          # Split name into first/last
          parts = name.split(" ", 2)
          first_name = parts[0]
          last_name = parts[1] || ""

          next if first_name.blank? || last_name.blank?

          contracts << {
            first_name: first_name,
            last_name: last_name,
            position: position,
            team_code: code,
            team_slug: team_slug,
            start_year: start_year.to_i,
            end_year: end_year.to_i,
            years: years.to_i,
            total_value_cents: total_cents,
            annual_value_cents: average_cents,
            guaranteed_cents: guaranteed_cents
          }
          team_count += 1
        end

        puts "  Found #{team_count} contracts"

      rescue StandardError => e
        puts "  ERROR: #{e.message}"
        errors << { code: code, team_slug: team_slug, error: e.message }
      end

      sleep 2 unless idx == spotrac_codes.size - 1
    end

    # Write JSON output
    output_path = Rails.root.join("tmp", Spotrac::SyncContracts::SNAPSHOT)
    File.write(output_path, JSON.pretty_generate(contracts))

    puts "\nDone! #{contracts.size} contracts written to #{output_path}"
    puts "To seed from it: bin/rails seed_data:publish FILE=#{output_path} NAME=#{Spotrac::SyncContracts::SNAPSHOT}, on a dyno, then bump its pin"
    puts "Teams with errors: #{errors.map { |e| e[:code] }.join(', ')}" if errors.any?

    # Show unique positions for debugging
    positions = contracts.map { |c| c[:position] }.tally.sort_by { |_, v| -v }
    puts "\nPositions found:"
    positions.each { |pos, count| puts "  #{pos}: #{count}" }
  end
end

def parse_dollars(str)
  return 0 if str.nil? || str.strip.empty? || str == "-"
  # "$106,000,000" → 10_600_000_000 (cents)
  str.gsub(/[$,]/, "").to_i * 100
end
