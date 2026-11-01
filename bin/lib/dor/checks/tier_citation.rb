# frozen_string_literal: true

require "yaml"
require_relative "../checks"

module Dor
  module Checks
    # A shape's `cited_tiers` must each name the test that covers them, in checks_run.
    # The tag alone is free text. A citation may be new or existing, so a tier asks for
    # evidence and never mints a test. The path's FORM refuses; a path missing from this
    # tree only advises, because review may run elsewhere. test/system answers [e2e]
    # only in a repo with no Playwright config. Review opens each citation.
    class TierCitation < Base
      CONFIG = File.expand_path("../../../../config/feature_shapes.yml", __dir__)
      RAILS_TEST = %r{(?:\A|[\s:=(])(test/\S+\.(?:rb|js|mjs|ts))}
      PLAYWRIGHT_TEST = %r{(?:\A|[\s:=(])(e2e/\S+\.spec\.(?:js|ts))}
      SYSTEM_TEST = %r{(?:\A|[\s:=(])(test/system/\S+\.rb)}
      PLAYWRIGHT_CONFIGS = %w[playwright.config.js playwright.config.ts].freeze

      def call(context)
        Array(shape_def(context)["cited_tiers"]).each do |tier|
          tagged = Array(context.devops["checks_run"]).grep(/\A\s*\[\s*#{Regexp.escape(tier)}\s*[\]:]/i)
          next if tagged.empty? # bin/dor-check already reports the missing tier.

          forms = forms_for(context, tier)
          paths = tagged.filter_map { |line| forms.filter_map { |form| line[form, 1] }.first }
          next refuse(context, tier, tagged.first) if paths.empty?

          advise(context, tier, paths)
        end
      end

      private

      def shape_def(context)
        config = YAML.safe_load_file(ENV.fetch("DOR_CHECK_SHAPES_CONFIG", CONFIG), aliases: true)
        config.dig("shapes", context.devops["shape"].to_s) || {}
      end

      def forms_for(context, tier)
        return [RAILS_TEST] unless tier == "e2e"

        playwright?(context) ? [PLAYWRIGHT_TEST] : [PLAYWRIGHT_TEST, SYSTEM_TEST]
      end

      # An unreadable root counts as a Playwright repo: the stricter form holds.
      def playwright?(context)
        root = context.diff_root.to_s
        !File.directory?(root) || PLAYWRIGHT_CONFIGS.any? { |name| File.exist?(File.join(root, name)) }
      end

      def refuse(context, tier, line)
        form = tier == "e2e" ? e2e_form(context) : "a test/ path"
        context.error("checks_run: the [#{tier}] line #{line.inspect} names no test. Cite #{form}, new or " \
                      "existing. New logic at this tier: a test that goes red when the change is reverted. " \
                      "No new logic: the test covering the surface it passes through, and say so on the line.")
      end

      def e2e_form(context)
        return "an e2e/*.spec.js path (this repo has Playwright)" if playwright?(context)

        "an e2e/*.spec.js or test/system/*.rb path"
      end

      def advise(context, tier, paths)
        found = paths.select { |path| context.changed_files.include?(path) || on_disk?(context, path) }
        return unless found.empty?

        context.suggest("checks_run: [#{tier}] cites #{paths.join(", ")}, not in this tree or the diff. " \
                        "Confirm the path; review opens every citation.")
      end

      def on_disk?(context, path)
        File.exist?(File.join(context.diff_root.to_s, path.split(":").first))
      end
    end
  end
end
