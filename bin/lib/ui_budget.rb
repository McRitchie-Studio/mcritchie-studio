# frozen_string_literal: true

require "json"
require "uri"
require "yaml"

# UiBudget — the evaluator half of bin/ui-budget. It reads the collector's JSON
# (bin/lib/ui_budget/collect.cjs) and config/ui_budget.yml, and turns each page,
# width and ceiling into one row with a verdict:
#
#   ok       within the ceiling
#   OVER     past it (a `max` exceeded, or a `min` not reached)
#   n/a      nothing to judge (no rendered image, no /assets/ request)
#   MISSING  the page, or a metric the ceiling needs, was never measured
#
# MISSING fails the run like OVER does. A host that is down, a page that 404s, or
# an axe pass that never ran would otherwise read as a clean night, and the point
# of the nightly is that silence means under budget.
#
# A ceiling may be scoped (`applies_to`): `landing_phone` judges only landing
# pages at a phone width, `not_sign_in` skips sign-in flows. An out-of-scope
# ceiling produces no row at all.
#
# Unit tests: test/lib/ui_budget_test.rb
module UiBudget
  class Error < StandardError; end

  ROOT = File.expand_path("../..", __dir__)
  CONFIG = File.join(ROOT, "config/ui_budget.yml")
  COLLECTOR = File.join(ROOT, "bin/lib/ui_budget/collect.cjs")

  # The eight ceilings, in the order the table prints them, and how each prints.
  UNITS = {
    "axe_serious_critical" => :count,
    "js_bytes" => :bytes,
    "third_party_js_bytes" => :bytes,
    "total_bytes" => :bytes,
    "largest_image_ratio" => :ratio,
    "html_raw_bytes" => :bytes,
    "css_bytes" => :bytes,
    "assets_cached_one_year_pct" => :percent
  }.freeze
  METRICS = UNITS.keys.freeze
  # A null here means there was nothing to measure, not that measuring failed.
  NULLABLE = %w[largest_image_ratio assets_cached_one_year_pct].freeze
  SCOPES = %w[landing_phone not_sign_in].freeze
  PHONE_MAX_WIDTH = 767

  Page = Struct.new(:app, :url, :landing, :sign_in, keyword_init: true)
  Config = Struct.new(:widths, :ceilings, :pages, keyword_init: true)
  Row = Struct.new(:page, :width, :metric, :value, :ceiling, :verdict, keyword_init: true)

  module_function

  def load_config(path = CONFIG)
    doc = YAML.safe_load_file(path)
    ceilings = doc.fetch("ceilings")
    unknown = ceilings.keys - METRICS
    raise Error, "#{path}: unknown ceiling(s) #{unknown.join(', ')}" if unknown.any?

    ceilings.each do |metric, spec|
      raise Error, "#{path}: #{metric} needs exactly one of max or min" unless spec.key?("max") ^ spec.key?("min")
      scope = spec["applies_to"]
      raise Error, "#{path}: #{metric} applies_to #{scope.inspect} is not one of #{SCOPES.join(', ')}" if scope && !SCOPES.include?(scope)
    end

    pages = doc.fetch("apps").flat_map do |app, spec|
      host = spec.fetch("host").chomp("/")
      spec.fetch("pages").map do |page|
        Page.new(app: app, url: host + page.fetch("path"), landing: page["landing"] == true, sign_in: page["sign_in"] == true)
      end
    end
    Config.new(widths: doc.fetch("widths").map(&:to_i), ceilings: ceilings, pages: pages)
  end

  def select_pages(config, only: nil)
    return config.pages unless only

    picked = config.pages.select { |p| p.url == only }
    raise Error, "#{only} is not in the config; add it to config/ui_budget.yml first" if picked.empty?
    picked
  end

  def evaluate(config, doc, only: nil)
    measured = (doc["results"] || []).to_h { |r| [[r["url"], r["width"].to_i], r] }
    select_pages(config, only: only).flat_map do |page|
      config.widths.flat_map do |width|
        result = measured[[page.url, width]]
        next [missing_page(page, width, "no result")] if result.nil?
        next [missing_page(page, width, result["error"].to_s)] if result["error"]

        judge_page(config, page, width, result.fetch("metrics", {}))
      end
    end
  end

  def missing_page(page, width, why)
    Row.new(page: page.url, width: width, metric: "page", value: why, ceiling: "measured", verdict: "MISSING")
  end

  def judge_page(config, page, width, metrics)
    METRICS.filter_map do |metric|
      spec = config.ceilings[metric]
      next unless spec && applies?(spec["applies_to"], page, width)

      judge(page, width, metric, spec, metrics)
    end
  end

  def applies?(scope, page, width)
    case scope
    when nil then true
    when "landing_phone" then page.landing && width <= PHONE_MAX_WIDTH
    when "not_sign_in" then !page.sign_in
    end
  end

  def judge(page, width, metric, spec, metrics)
    limit = spec["max"] || spec["min"]
    ceiling = "#{spec.key?('max') ? '<=' : '>='} #{format_value(metric, limit)}"
    value = metrics[metric]
    verdict =
      if !metrics.key?(metric) || (value.nil? && !NULLABLE.include?(metric)) then "MISSING"
      elsif value.nil? then "n/a"
      elsif spec.key?("max") then value > limit ? "OVER" : "ok"
      else value < limit ? "OVER" : "ok"
      end
    shown = value.nil? ? "-" : format_value(metric, value)
    Row.new(page: page.url, width: width, metric: metric, value: shown, ceiling: ceiling, verdict: verdict)
  end

  def format_value(metric, value)
    case UNITS.fetch(metric)
    when :bytes then "#{(value / 1024.0).round} KB"
    when :ratio then format("%.2fx", value)
    when :percent then value.is_a?(Integer) ? "#{value}%" : format("%.1f%%", value)
    else value.to_s
    end
  end

  def over?(rows) = rows.any? { |r| %w[OVER MISSING].include?(r.verdict) }

  COLUMNS = %i[page width metric value ceiling verdict].freeze

  def verdict_line(rows)
    tally = rows.map(&:verdict).tally
    pages = rows.map { |r| [r.page, r.width] }.uniq.size
    "ui-budget: #{tally.fetch('OVER', 0)} over, #{tally.fetch('MISSING', 0)} missing, " \
      "#{tally.fetch('ok', 0)} ok across #{pages} page-width(s)"
  end

  def table(rows)
    cells = [COLUMNS.map(&:to_s)] + rows.map { |r| COLUMNS.map { |c| r[c].to_s } }
    widths = COLUMNS.each_index.map { |i| cells.map { |row| row[i].length }.max }
    lines = cells.map { |row| row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
    (lines + ["", verdict_line(rows)]).join("\n") + "\n"
  end

  def markdown(rows)
    head = "| #{COLUMNS.join(' | ')} |\n|#{COLUMNS.map { '---' }.join('|')}|\n"
    body = rows.map { |r| "| #{COLUMNS.map { |c| r[c].to_s.gsub('|', '\|') }.join(' | ')} |\n" }.join
    "## UI budget\n\n#{verdict_line(rows)}\n\n#{head}#{body}"
  end
end
