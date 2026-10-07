# frozen_string_literal: true

require "test_helper"
require "yaml"

# [unit] A QA app that serves a custom domain must declare APP_HOST, or it inherits
# the consumer's production default and mints production links from a review
# environment. mcritchie-industries carried that hazard until 2026-07-29.
#
# Scoped to entries with a custom domain: rolio's qa_url is the raw herokuapp.com
# host, and its app never reads APP_HOST. (QA_ENV needs no check here:
# QaServerCli.with_qa_marker stamps it on every entry; test/lib/qa_marker_test.rb.)
class QaRegistryAppHostTest < ActiveSupport::TestCase
  REGISTRY = Rails.root.join("config", "qa_environments.yml")

  test "a QA environment with a custom domain declares APP_HOST" do
    entries = YAML.load_file(REGISTRY).fetch("qa_environments")
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
