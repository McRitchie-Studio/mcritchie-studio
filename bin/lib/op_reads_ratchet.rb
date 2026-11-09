# frozen_string_literal: true

require "yaml"
require "date"
require "time"

# OpReadsRatchet — the 1Password reads ratchet (task agent-op-reads-ratchet).
# Config: config/op_direct_callers.yml. Query: `bin/op-reads --ratchet`. Guard:
# test/lib/op_direct_callers_ratchet_test.rb. Doc:
# docs/agents/modules/credential-access.md, "The ratchet".
#
# Two numbers that may only go down: `daily_cap`, the most `op` calls agents may
# make in a rolling 24 hours, and `callers`, the files that run `op` themselves.
# This file reads the config and counts the log rows; it runs no `op` and writes
# nothing.
#
# WHAT COUNTS. A row of the read log (OpMeter) counts when it is an `op` call
# that could have spent the account's quota:
#   * not bookkeeping: `cache-hit`, `soul-refused`, `admin-refused` and
#     `auth-refresh` rows record a decision, not a call;
#   * not `timeout`: a killed attempt never reached the server;
#   * not `fail:126` or `fail:127`: `op` was absent or not executable.
# A failed read (`fail:1`) DOES count: the server answered it.
#
# Ruby 2.6 syntax (bin/op-reads runs under system Ruby in places).
module OpReadsRatchet
  CONFIG_ENV = "MCR_OP_RATCHET_CONFIG"
  BOOKKEEPING = %w[cache-hit soul-refused admin-refused auth-refresh].freeze
  NO_QUOTA = /\A(?:timeout|fail:12[67])\z/.freeze
  WINDOW_SECONDS = 86_400
  CLIENTS_SELF = %w[self remedy-text].freeze

  class ConfigError < StandardError; end

  module_function

  def config_path(env = ENV)
    override = env[CONFIG_ENV].to_s.strip
    override.empty? ? File.expand_path("../../config/op_direct_callers.yml", __dir__) : File.expand_path(override)
  end

  def config(env = ENV)
    validate!(YAML.safe_load(File.read(config_path(env)), permitted_classes: [Date], aliases: false))
  rescue Errno::ENOENT
    raise ConfigError, "op reads ratchet: no config at #{config_path(env)}"
  rescue Psych::SyntaxError => e
    raise ConfigError, "op reads ratchet: #{config_path(env)} is not valid YAML (#{e.message})"
  end

  # The config, checked. Raises ConfigError naming the first fault.
  def validate!(data)
    raise ConfigError, "op reads ratchet: the config is not a map" unless data.is_a?(Hash)

    cap = data["daily_cap"]
    raise ConfigError, "op reads ratchet: daily_cap must be a positive Integer, got #{cap.inspect}" unless cap.is_a?(Integer) && cap.positive?

    history = data["cap_history"]
    unless history.is_a?(Array) && !history.empty? && history.all? { |h| h.is_a?(Hash) && h["cap"].is_a?(Integer) }
      raise ConfigError, "op reads ratchet: cap_history must be a list of rows that each carry an Integer `cap`"
    end
    history.each_cons(2) do |before, after|
      next if after["cap"] <= before["cap"]

      raise ConfigError, "op reads ratchet: cap_history rises from #{before['cap']} to #{after['cap']}; the cap only goes down"
    end
    unless history.last["cap"] == cap
      raise ConfigError, "op reads ratchet: daily_cap #{cap} is not the last cap_history row (#{history.last['cap']})"
    end

    callers = data["callers"]
    raise ConfigError, "op reads ratchet: callers must be a map of path => {client, why}" unless callers.is_a?(Hash)

    callers.each do |path, meta|
      ok = meta.is_a?(Hash) && !meta["client"].to_s.strip.empty? && !meta["why"].to_s.strip.empty?
      raise ConfigError, "op reads ratchet: callers.#{path} needs a `client` and a `why`" unless ok
    end
    data
  end

  # True when a log row is an `op` call that could have spent quota.
  def counted?(row)
    !BOOKKEEPING.include?(row["action"].to_s) && !NO_QUOTA.match?(row["outcome"].to_s)
  end

  def row_time(row)
    Time.parse(row["ts"].to_s).utc
  rescue ArgumentError, TypeError
    nil
  end

  # The counted rows of the rolling window that ends at +now+. A row whose time
  # will not parse is KEPT: a total that quietly drops rows stops adding up.
  def window(rows, now: Time.now)
    floor = now.utc - WINDOW_SECONDS
    rows.select do |row|
      next false unless counted?(row)

      t = row_time(row)
      t.nil? || (t > floor && t <= now.utc)
    end
  end

  # { "count", "cap", "over", "callers" => [{ "caller", "reads", "via" }] },
  # callers ranked by reads, most first. `via` is the top three seams.
  def report(rows, cfg, now: Time.now)
    counted = window(rows, now: now)
    callers = counted.group_by { |r| r["caller"].to_s }.map do |caller, group|
      vias = group.map { |r| r["via"].to_s }.tally.sort_by { |v, n| [-n, v] }.first(3)
      { "caller" => caller, "reads" => group.size, "via" => vias.map { |v, n| "#{v}×#{n}" }.join(" ") }
    end
    callers.sort_by! { |c| [-c["reads"], c["caller"]] }
    { "count" => counted.size, "cap" => cfg["daily_cap"], "over" => counted.size > cfg["daily_cap"],
      "callers" => callers }
  end

  def lines(rep, top: 10)
    verdict = rep["over"] ? "OVER the cap" : "under the cap"
    out = ["1Password reads ratchet: #{rep['count']} op call(s) in the last 24h; daily_cap #{rep['cap']} " \
           "(config/op_direct_callers.yml): #{verdict}.", ""]
    rep["callers"].first(top).each do |c|
      out << format("  %-28s %5d  %s", c["caller"], c["reads"], c["via"])
    end
    hidden = rep["callers"].size - top
    out << "  ... #{hidden} more caller(s): --by caller" if hidden.positive?
    out << ""
    out << if rep["over"]
             "  Over the cap: find the caller above that grew, and move it behind a cached client " \
               "(credential-access.md, the read order). The cap is never raised."
           else
             "  Under the cap for a week? Lower daily_cap to the new peak (add a cap_history row)."
           end
    out
  end
end
