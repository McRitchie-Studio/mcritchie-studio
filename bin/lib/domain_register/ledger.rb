# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module DomainRegister
  # The purchase ledger: one JSON line per event, appended, never rewritten.
  #
  #   authorized  written BEFORE the registration POST: the domain, the exact
  #               price and renewal, Alex's words (--ok), who ran it, when.
  #   registered  the workflow reached `succeeded`.
  #   failed      the POST or the workflow failed, with Cloudflare's message.
  #   pending     the poll timed out with the workflow still running.
  #
  # Writing `authorized` first means a crash mid-purchase still leaves a record
  # that money may have moved, and on whose word.
  #
  # Lives at <projects>/.agents/ledgers/domain-registrations.jsonl: the shared
  # agent state beside every primary, outside any desk (a reclaimed desk cannot
  # take it) and outside every repo (the hub repo is public). Override with
  # DOMAIN_REGISTER_LEDGER (the tests do).
  class Ledger
    ENV_PATH = "DOMAIN_REGISTER_LEDGER"

    def self.default_path
      require_relative "../projects_root"
      File.join(ProjectsRoot.default_projects_dir, ".agents", "ledgers", "domain-registrations.jsonl")
    end

    attr_reader :path

    def initialize(path = ENV[ENV_PATH].to_s.empty? ? self.class.default_path : ENV[ENV_PATH])
      @path = path
    end

    def append(event)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, "a") { |f| f.puts(JSON.generate(event)) }
      event
    end

    def entries
      return [] unless File.exist?(@path)

      File.readlines(@path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    end
  end
end
