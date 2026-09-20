# frozen_string_literal: true

require "test_helper"

# [unit] Every hub CLI that talks to the board must default to the CANONICAL host.
#
# lib/middleware/canonical_host.rb now 301s the vanity aliases onto the apex, and our
# own tooling was pointed at one of them: bin/devops-cycle and bin/review-autopilot
# both defaulted TASK_BOARD_URL to https://www.mcritchie.studio while the other nine
# board CLIs used the apex. bin/lib/task_board.rb issues a bare Net::HTTP request and
# does NOT follow a 3xx, so the day that redirect reaches production those two would
# have started reading the redirect instead of the API.
#
# It would not even have failed loudly. TaskBoard.parse_body is deliberately lenient,
# so the 301's HTML body parses to {} and bin/review-autopilot — the tool that lands
# armed merges — dies complaining it "could not resolve a head sha".
#
# The two literals were the bug; this test is the fix. A default host is a one-word
# edit that no reviewer reads closely, and nothing else in the suite looks at it.
class BoardCliCanonicalHostTest < ActiveSupport::TestCase
  CANONICAL = "mcritchie.studio"

  # The hosts CanonicalHost redirects. qa.mcritchie.studio is deliberately absent: it
  # is a separate deploy target with its own APP_HOST, not an alias of this one.
  REDIRECTED_ALIASES = %w[www.mcritchie.studio app.mcritchie.studio].freeze

  # ENV.fetch("SOME_URL", "https://host/…") — the shape every board CLI uses to name
  # its default. Nested fetches match on the inner one, which is the default that ships.
  ENV_DEFAULT = /ENV\.fetch\(\s*"([A-Z0-9_]+)"\s*,\s*"(https?:\/\/[^"]+)"/

  def self.scripts
    @scripts ||= Dir.glob(Rails.root.join("bin/**/*"))
                    .select { |path| File.file?(path) }
                    .sort
  end

  def relative(path) = Pathname(path).relative_path_from(Rails.root).to_s

  test "there are hub scripts to inspect" do
    # The reflex on an empty glob is a green test. It would be green forever.
    assert_operator self.class.scripts.length, :>, 20,
                    "bin/ should hold the hub's scripts; an empty glob makes every case below vacuous"
  end

  test "every ENV-defaulted board URL under our domain names the canonical host" do
    offenders = self.class.scripts.flat_map do |path|
      File.read(path).scan(ENV_DEFAULT).filter_map do |var, url|
        host = URI.parse(url).host.to_s.downcase
        next unless host.end_with?(CANONICAL)
        next if host == CANONICAL

        "#{relative(path)}: #{var} defaults to #{host}"
      end
    rescue URI::InvalidURIError
      next []
    end

    assert_empty offenders,
                 "these defaults point at a host CanonicalHost redirects, and the board " \
                 "client does not follow redirects:\n  #{offenders.join("\n  ")}"
  end

  test "no hub script hardcodes a redirected alias in its code" do
    offenders = self.class.scripts.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")           # prose may name an alias to explain it
        next unless REDIRECTED_ALIASES.any? { |host| line.include?(host) }

        "#{relative(path)}:#{index + 1}"
      end
    end

    assert_empty offenders,
                 "a redirected alias is baked into executable lines here: #{offenders.join(", ")}"
  end
end
