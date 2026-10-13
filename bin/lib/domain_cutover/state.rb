# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module DomainCutover
  # Where a cutover remembers itself between phases: one JSON per domain under
  # the hub primary's tmp/domain-cutover/ (gitignored, and outside any desk, so a
  # reclaimed desk cannot take a half-finished move's state with it). The phases
  # are hours apart (finalize waits six), so the state must outlive the shell.
  #
  # Override the directory with DOMAIN_CUTOVER_STATE_DIR (the tests do).
  class StateStore
    ENV_DIR = "DOMAIN_CUTOVER_STATE_DIR"

    def self.default_dir
      require_relative "../projects_root"
      File.join(ProjectsRoot.hub_checkout, "tmp", "domain-cutover")
    end

    def initialize(dir = ENV[ENV_DIR].to_s.empty? ? self.class.default_dir : ENV[ENV_DIR])
      @dir = dir
    end

    def path(domain) = File.join(@dir, "#{Records.name(domain)}.json")

    def load(domain)
      file = path(domain)
      File.exist?(file) ? JSON.parse(File.read(file)) : nil
    end

    # Written whole to a temp file and renamed, so a crash never leaves half a state.
    def save(domain, state)
      FileUtils.mkdir_p(@dir)
      tmp = "#{path(domain)}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(state)}\n")
      File.rename(tmp, path(domain))
      state
    end
  end
end
