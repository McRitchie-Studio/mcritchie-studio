# frozen_string_literal: true

require "yaml"
require_relative "../checks"

module Dor
  module Checks
    # A shape's `cited_tiers` must each name the test that covers them, in checks_run.
    # The tag alone is free text. A citation may be a new test or an existing one, so a
    # tier asks for evidence and never mints a test. The path's FORM refuses; a path
    # missing from this tree only advises, because review runs from a foreign checkout.
    class TierCitation < Base
      CONFIG = File.expand_path("../../../../config/feature_shapes.yml", __dir__)
      RAILS_TEST = %r{(?:\A|[\s:=(])(test/\S+\.(?:rb|js|mjs|ts))}
      BROWSER_TEST = %r{(?:\A|[\s:=(])((?:e2e/\S+\.spec\.(?:js|ts)|test/system/\S+\.rb))}

      def call(context)
        Array(shape_def(context)["cited_tiers"]).each do |tier|
          tagged = Array(context.devops["checks_run"]).grep(/\A\s*\[\s*#{Regexp.escape(tier)}\s*[\]:]/i)
          next if tagged.empty? # bin/dor-check already reports the missing tier.

          paths = tagged.filter_map { |line| line[tier == "e2e" ? BROWSER_TEST : RAILS_TEST, 1] }
          next refuse(context, tier, tagged.first) if paths.empty?

          advise(context, tier, paths)
        end
      end

      private

      def shape_def(context)
        config = YAML.safe_load_file(ENV.fetch("DOR_CHECK_SHAPES_CONFIG", CONFIG), aliases: true)
        config.dig("shapes", context.devops["shape"].to_s) || {}
      end

      def refuse(context, tier, line)
        form = tier == "e2e" ? "an e2e/*.spec.js or test/system/*.rb path" : "a test/ path"
        context.error("checks_run: the [#{tier}] line #{line.inspect} names no test. Cite #{form}, new or " \
                      "existing: the one that exercises this change, and goes red if the change is reverted.")
      end

      def advise(context, tier, paths)
        found = paths.select { |path| context.changed_files.include?(path) || on_disk?(context, path) }
        return unless found.empty?

        context.suggest("checks_run: [#{tier}] cites #{paths.join(", ")}, not in this tree or the diff. " \
                        "Confirm the path; review will re-run it.")
      end

      def on_disk?(context, path)
        File.exist?(File.join(context.diff_root.to_s, path.split(":").first))
      end
    end
  end
end
