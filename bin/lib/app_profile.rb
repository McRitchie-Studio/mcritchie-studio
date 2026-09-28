# frozen_string_literal: true

require "yaml"

# AppProfile — expands a deploy profile from config/app_profiles.yml into the
# release_repos.yml entry every registry reader already understands, renders it
# as YAML text for bin/register-app to append, and answers whether an existing
# entry still matches its profile (the drift guard repos_test.rb runs).
#
# Why generated rather than expanded at read time: config/app_profiles.yml's
# header. The SOP: docs/agents/agents/steffon/sops/app-deploy-standard.md.
#
# Unit tests: test/lib/app_profile_test.rb
module AppProfile
  PROFILES_PATH = File.expand_path("../../config/app_profiles.yml", __dir__)
  PARAMS = %w[heroku_app smoke_url test_cmd].freeze

  class Error < StandardError; end

  module_function

  def profiles(path = PROFILES_PATH)
    (YAML.safe_load_file(path) || {}).fetch("profiles", {})
  end

  def profile(name, path = PROFILES_PATH)
    profiles(path).fetch(name.to_s) { raise Error, "unknown profile #{name.inspect} (known: #{profiles(path).keys.join(', ')})" }
  end

  # The full registry entry for one app. Every PARAMS value is required and must
  # be a single line: a blank one would write a registry row that ships nowhere,
  # and a newline would forge extra YAML.
  def expand(name, params, path = PROFILES_PATH)
    values = PARAMS.to_h { |key| [key.to_sym, params.fetch(key.to_sym) { params[key] }.to_s.strip] }
    missing = values.select { |_k, v| v.empty? }.keys
    raise Error, "profile #{name} needs #{missing.join(', ')}" unless missing.empty?
    bad = values.select { |_k, v| v.include?("\n") }.keys
    raise Error, "#{bad.join(', ')} must be a single line" unless bad.empty?

    { "profile" => name.to_s }.merge(fill(profile(name, path).fetch("entry"), values))
  end

  def fill(node, values)
    case node
    when Hash then node.transform_values { |v| fill(v, values) }
    when String then format(node, values)
    else node
    end
  end

  # The params an EXISTING entry was built from, read back out of it, so the
  # drift guard can re-expand and compare. Nil when the entry cannot be read as
  # this profile at all (the comparison then reports the whole entry).
  def params_of(entry)
    remote = entry.dig("prod_deploy", "remote").to_s
    heroku_app = remote[%r{\Ahttps://git\.heroku\.com/([a-z0-9-]+)\.git\z}, 1]
    return nil unless heroku_app

    { heroku_app: heroku_app, smoke_url: entry.dig("prod_deploy", "smoke_url"), test_cmd: entry["test_cmd"] }
  end

  # Differences between an entry and what its declared profile expands to, as
  # human-readable lines; empty means the entry is exactly the profile.
  def drift(entry, path = PROFILES_PATH)
    name = entry["profile"].to_s
    params = params_of(entry)
    return ["cannot read heroku_app from prod_deploy.remote #{entry.dig('prod_deploy', 'remote').inspect}"] unless params

    expected = expand(name, params, path)
    diff_lines(expected, entry)
  rescue Error => e
    [e.message]
  end

  def diff_lines(expected, actual, prefix = "")
    keys = (expected.keys + actual.keys).uniq
    keys.flat_map do |key|
      e = expected[key]
      a = actual[key]
      if e.is_a?(Hash) && a.is_a?(Hash)
        diff_lines(e, a, "#{prefix}#{key}.")
      elsif e == a
        []
      else
        ["#{prefix}#{key}: expected #{e.inspect}, found #{a.inspect}"]
      end
    end
  end

  # The YAML text for one entry under `apps:` (two-space indent), with a short
  # generated header in place of the per-app essays the registry used to carry.
  def render(slug, entry, notes: [])
    body = YAML.dump(entry).sub(/\A---\n/, "").lines.map { |line| "    #{line}" }.join
    header = ["  #{slug}:",
              "    # Registered by bin/register-app on profile #{entry['profile']}. The contract, the",
              "    # QA decision and how to leave the profile: config/app_profiles.yml and the",
              "    # app-deploy-standard SOP. To change it, edit it by hand; repos_test.rb",
              "    # fails if this entry drifts from the profile."]
    header += notes.map { |note| "    # #{note}" }
    "#{header.join("\n")}\n#{body}"
  end
end
