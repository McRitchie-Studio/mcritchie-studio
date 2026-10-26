# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module DomainRegister
  # The purchase ledger: one JSON line per event, appended, never rewritten.
  #
  #   authorized  written BEFORE the registration POST: the domain, the exact
  #               price and renewal, Alex McRitchie's words (--ok), who ran it, when.
  #   registered  the workflow reached `succeeded`.
  #   failed      `failure: rejected`: Cloudflare answered the POST with a 4xx,
  #               so no registration started; `failure: workflow`: the
  #               workflow itself ended `failed`.
  #   unknown     the POST (or a poll) got NO answer, or a 5xx: money MAY have
  #               moved.
  #   pending     the poll timed out, or a person must act, with the workflow open.
  #   no_workflow `status` found no workflow for an authorization at least
  #               SETTLE_SECONDS old: nothing was bought.
  #
  # An `authorized` line is OPEN until a later registered, failed or
  # no_workflow line for the same domain closes it. register refuses while one is
  # open (#open_authorization), so an unknown outcome can never be bought twice.
  #
  # Writing `authorized` first means a crash mid-purchase still leaves a record
  # that money may have moved, and on whose word.
  #
  # Lives in the hub primary's tmp/domain-register/registrations.jsonl, beside
  # bin/domain-cutover's state: gitignored (the hub repo is public), outside any
  # desk (a reclaimed desk cannot take it), and outside the shared agent store, which
  # only sandbox-guarded stores may name (test/lib/state_store_containment_test.rb).
  # bin/clean-artifacts sweeps only tmp/cache, never this. Override with
  # DOMAIN_REGISTER_LEDGER (the tests do).
  #
  # A writing run (register, status) holds an exclusive flock on <path>.lock for
  # its whole length (#exclusively). Without it two concurrent register runs
  # could both read "no open authorization" before either wrote its
  # `authorized` line, and buy twice; or a status could close an authorization
  # another run was about to act on. A second run REFUSES at once rather than
  # waiting (a register can poll for ten minutes), and has written nothing.
  class Ledger
    ENV_PATH = "DOMAIN_REGISTER_LEDGER"

    def self.default_path
      require_relative "../projects_root"
      File.join(ProjectsRoot.hub_checkout, "tmp", "domain-register", "registrations.jsonl")
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

    # Runs the block holding the ledger's lock; raises Abort, having run nothing,
    # when another run holds it. The lock is released when the block returns or
    # raises (and by the OS if the process dies).
    def exclusively(what)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Abort, "REFUSED, nothing ran: another bin/domain-register run holds the ledger " \
                       "(#{lock_path}). Wait for it to finish, then #{what} again."
        end

        yield
      end
    end

    def lock_path = "#{@path}.lock"

    CLOSING = %w[registered failed no_workflow].freeze

    # The newest `authorized` line for the domain that nothing after it has
    # closed, or nil.
    def open_authorization(domain)
      open = nil
      entries.each do |e|
        next unless e["domain"] == domain

        if e["event"] == "authorized"
          open = e
        elsif CLOSING.include?(e["event"])
          open = nil
        end
      end
      open
    end

    def entries
      return [] unless File.exist?(@path)

      File.readlines(@path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    end
  end
end
