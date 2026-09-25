# frozen_string_literal: true

require "yaml"

# ReleaseRegistry — what config/release_repos.yml DECLARES about a repo's test lane.
#
# Read by bin/fast-check to decide which command is a checkout's suite. Every rule
# here is DECLARED, never inferred: nothing probes a checkout for bin/rails or
# sniffs a Gemfile. A repo gets a registry test command because its row names one;
# an unrecognised slug or an unreadable registry answers nil/false and the caller
# falls back to the ordinary Rails lanes, which fails CLOSED.
module ReleaseRegistry
  REGISTRY_PATH = File.expand_path("../../config/release_repos.yml", __dir__)

  module_function

  # The repo's own gate command (`release_check:` on its row), or nil. A gem repo
  # has no ci.yml for CiTestCommand to read and no `bin/rails` to prepare a test DB
  # with; its row carries the command that IS its suite (bin/release-check).
  def release_check_cmd(repo)
    slug = repo.to_s.strip
    return nil if slug.empty?

    cmd = repo_registry.dig(slug, "release_check").to_s.strip
    cmd.empty? ? nil : cmd
  end

  # TRUE for a repo the registry files under `gems`. A gem has no test database and
  # no bin/rails to prepare one with, so the Rails prepare lane never applies to it.
  def gem_repo?(repo)
    slug = repo.to_s.strip
    return false if slug.empty?

    repo_sections[slug] == "gems"
  end

  # TRUE for a repo that DECLARES ITS OWN GATE COMMAND, or is a gem. A declared
  # `release_check` says "this command IS this repo's suite", so bin/fast-check runs
  # it as the whole lane and skips the Rails test-prepare that precedes a mapped
  # lane. The section check stays in the `||` because a gem that omits
  # release_check still has no test database (keep the skip), while an `apps` row
  # that declares one — turf-vault — must get it. Keying on the section alone was
  # the defect (turf-vault had no lane); keying on the command alone would re-arm a
  # Rails lane against a gem.
  def registry_gated?(repo)
    gem_repo?(repo) || !release_check_cmd(repo).nil?
  end

  # TRUE when the row declares `lint_lane: none` — a repo that ships no rubocop at
  # all (studio-engine, solana-studio, turf-vault). Declared, never inferred from a
  # missing binary: a repo whose rubocop cannot launch and whose row says nothing
  # stays a red lane.
  def lint_waived?(repo)
    slug = repo.to_s.strip
    return false if slug.empty?

    repo_registry.dig(slug, "lint_lane").to_s == "none"
  end

  # repo slug => "apps" | "gems".
  def repo_sections
    @repo_sections ||= begin
      cfg = YAML.safe_load_file(REGISTRY_PATH) || {}
      %w[apps gems].each_with_object({}) do |section, out|
        (cfg[section] || {}).each { |slug, row| out[slug] = section if row.is_a?(Hash) }
      end
    rescue StandardError
      {}
    end
  end

  # repo slug => its registry row, flattened across the apps/gems sections. Read
  # once. A registry that cannot be read declares NOTHING — the fail-closed rule.
  def repo_registry
    @repo_registry ||= begin
      cfg = YAML.safe_load_file(REGISTRY_PATH) || {}
      %w[apps gems].each_with_object({}) do |section, out|
        (cfg[section] || {}).each { |slug, row| out[slug] = row if row.is_a?(Hash) }
      end
    rescue StandardError
      {}
    end
  end
end
