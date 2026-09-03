# frozen_string_literal: true

require "test_helper"
require "yaml"

# [unit] THE PERMANENT GUARD over config/qa_environments.yml.
#
# Every QA app runs Rails in PRODUCTION mode — none sets RAILS_ENV — so `QA_ENV`
# is the only thing separating a review target from real production. Three
# separate consumers read it: Studio::EnvironmentBanner (the banner), turf-monster's
# AppFlags.qa_environment?, and (as of studio-s3-ignores-qa_env) Studio::S3 and
# Active Storage for bucket selection.
#
# An entry that omits it therefore does not fail loudly — it resolves the
# PRODUCTION bucket while holding the dev key, which is an AccessDenied on every
# write and a LIST of production objects from a review app. That is exactly what
# happened to mcritchie-industries: the marker was missing, nothing detected it,
# and it surfaced only when someone traced a silent upload failure by hand.
#
# The one-off YAML parses in that fix proved the state of the file THAT DAY. This
# is the committed guard that keeps proving it.
class QaRegistryDeclaresQaEnvTest < ActiveSupport::TestCase
  REGISTRY = Rails.root.join("config", "qa_environments.yml")

  def entries
    YAML.load_file(REGISTRY).fetch("qa_environments")
  end

  test "every QA environment declares the QA_ENV marker" do
    missing = entries.reject { |_slug, cfg| (cfg["required_config"] || {}).key?("QA_ENV") }.keys

    assert_empty missing,
                 "these QA entries declare no QA_ENV: #{missing.inspect}. Without it the app " \
                 "boots as production and every QA_ENV reader — the banner, AppFlags, and S3 " \
                 "bucket selection — treats a review target as real production."
  end

  test "the QA_ENV marker is truthy, since presence alone is not the contract" do
    falsy = entries.filter_map do |slug, cfg|
      value = (cfg["required_config"] || {})["QA_ENV"]
      slug unless %w[true 1 yes on].include?(value.to_s.strip.downcase)
    end

    assert_empty falsy,
                 "these entries declare a NON-TRUTHY QA_ENV: #{falsy.inspect}. " \
                 "EnvironmentBanner.truthy? owns the reading, so `QA_ENV=false` is production."
  end

  # A QA app that declares no APP_HOST inherits the consumer's production default
  # and mints production links from a review environment. mcritchie-industries
  # carried that hazard until 2026-07-29.
  #
  # SCOPED TO ENTRIES WITH A CUSTOM DOMAIN, deliberately. The first version of this
  # asserted it of EVERY entry and failed on rolio — whose qa_url is the raw
  # herokuapp.com host, which has no custom domain and whose app never reads
  # APP_HOST at all (verified: no reference in rolio's config/ or app/). That was
  # the test being wrong, not rolio. Loosening it to pass would have thrown away
  # the assertion; binding it to the CONDITION that makes APP_HOST load-bearing
  # keeps it sharp where it matters.
  test "a QA environment with a custom domain declares APP_HOST" do
    missing = entries.filter_map do |slug, cfg|
      next if Array(cfg["custom_domains"]).empty?

      slug unless (cfg["required_config"] || {}).key?("APP_HOST")
    end

    assert_empty missing,
                 "these QA entries serve a CUSTOM DOMAIN but declare no APP_HOST: " \
                 "#{missing.inspect}. The consumer's production default then wins and QA " \
                 "mints production links from a review environment."
  end
end
