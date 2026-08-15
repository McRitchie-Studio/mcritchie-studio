# frozen_string_literal: true

require "pathname"

# THE CHECK REGISTRY — and the reason it is a DIRECTORY GLOB and not a list.
#
# bin/dor-check is 2560 lines and was touched by 24 of the last 200 merged PRs.
# Three separate tasks in one wave on 2026-08-14 all needed to edit it, and they had
# to be serialised by hand to avoid a guaranteed three-way conflict — that
# serialisation is the only reason the wave landed at all.
#
# The conflict was never the file's SIZE. It was the REGISTRATION POINT. Adding one
# check meant editing three shared regions: a require_relative near the top, a helper
# block mid-file, and a hook inside the merge-gate branch. Every one of those is a
# line the next agent also wants, so two agents adding two unrelated checks collide
# on lines that have nothing to do with either change.
#
# So the rule this file encodes: A DIRECTORY GLOB HAS NO MERGE CONFLICT, A LIST OF
# REQUIRES DOES. A check is one file under checks/. It is discovered by globbing that
# directory and it registers ITSELF by subclassing Base (Ruby's `inherited` hook), so
# adding a check is a PURE FILE ADD — no registry line, no require line, no hook.
# Two agents adding two checks now touch two disjoint files and cannot conflict.
#
# Splitting bin/dor-check into smaller files would NOT have achieved this on its own;
# whatever file held the list would simply become the new contention point.
module Dor
  module Checks
    # DOR_CHECKS_DIR is the test seam, mirroring dor-check's DOR_CHECK_* seams.
    #
    # It exists because the obvious way to prove this seam works — drop a file into the
    # real directory, run the gate, delete it — mutates state SHARED BY THE WHOLE
    # SUITE. It passed locally and failed in CI, where the suite runs in parallel
    # processes: one worker's probe file was on disk while another worker ran a test
    # asserting no such check existed. A test that writes into the repo it is testing
    # is not isolated, however carefully it cleans up after itself.
    DEFAULT_CHECKS_DIR = Pathname.new(__dir__).join("checks").freeze
    CHECKS_DIR = Pathname.new(ENV.fetch("DOR_CHECKS_DIR", DEFAULT_CHECKS_DIR.to_s)).freeze

    class << self
      def registry
        @registry ||= []
      end

      # Idempotent: `load!` may run more than once in a process (the test harness
      # drives it directly), and requiring an already-loaded file is a no-op while
      # re-registering a class would double-run its check.
      def register(klass)
        registry << klass unless registry.include?(klass)
        klass
      end

      # Discover every check. SORTED, so the order checks run — and therefore the
      # order their findings appear in the verdict — is deterministic and reviewable
      # rather than filesystem-dependent.
      def load!(dir = CHECKS_DIR)
        Dir.glob(File.join(dir.to_s, "*.rb")).sort.each { |file| require file }
        registry
      end

      # The checks that belong to a phase. :merge runs at the merge gate, :build at
      # the build gate, :both at either. A check that names no phase is a MERGE check,
      # because that is the gate that judges a diff.
      def for_phase(phase)
        registry.select { |k| k.phase == phase || k.phase == :both }
                .sort_by(&:check_name)
      end

      # Run every check for `phase` against `context`, folding each one's findings in.
      #
      # A check that RAISES is contained: it records the failure as an error naming
      # the check, and the remaining checks still run. A gate that dies halfway
      # through reports a verdict about a subset of itself while looking complete,
      # which is the same class of defect the checks exist to catch.
      def run(phase, context)
        for_phase(phase).each do |klass|
          klass.new.call(context)
        rescue StandardError => e
          context.error("check #{klass.check_name} FAILED to run (#{e.class}: #{e.message}) — " \
                        "this is a fault in the gate itself, not a verdict about the diff; " \
                        "the remaining checks still ran")
        end
        context
      end

      # Test seam: drop the registry so a suite can load a fixture directory without
      # inheriting the real checks.
      def reset!
        @registry = []
      end
    end

    # Subclass this and the check is registered. That is the whole contract.
    #
    #   class MyCheck < Dor::Checks::Base
    #     def self.phase = :merge
    #     def call(ctx)
    #       ctx.error("...") if something_wrong
    #     end
    #   end
    class Base
      def self.inherited(subclass)
        super
        Dor::Checks.register(subclass)
      end

      def self.phase
        :merge
      end

      # snake_case of the class's own name — used for ordering and for naming the
      # check in a fault message. Derived, so a check never has to declare it.
      #
      # TWO passes, not one. A single /([a-z\d])([A-Z])/ never splits consecutive
      # capitals, so AExplodingCheck came out "aexploding_check" and a CIStatusCheck
      # would read "cistatus_check" — a fault message that misnames the check it is
      # reporting is worse than one that says nothing. The first pass breaks an
      # acronym away from the word that follows it; the second breaks the ordinary
      # lower-to-upper boundary.
      def self.check_name
        name.to_s.split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
      end

      def call(_context)
        raise NotImplementedError, "#{self.class.check_name} must implement #call(context)"
      end
    end
  end
end
