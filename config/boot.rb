ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

begin
  require "bundler/setup" # Set up gems listed in the Gemfile.
rescue StandardError => e
  # ONLY the missing-gem case, and it is RE-RAISED either way — this explains the
  # failure, it never swallows it. A release publishes the gem and ref-pushes
  # main without installing anything locally, so the first script run in a
  # caught-up checkout dies here with a trace that names no cause. See
  # lib/boot_gem_diagnosis.rb.
  raise unless defined?(Bundler::GemNotFound) && e.is_a?(Bundler::GemNotFound)

  require_relative "../lib/boot_gem_diagnosis"
  warn BootGemDiagnosis.explain(e.message, root: File.expand_path("..", __dir__))
  raise
end

require "bootsnap/setup" # Speed up boot time by caching expensive operations.
