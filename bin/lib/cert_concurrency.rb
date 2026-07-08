# frozen_string_literal: true

require "etc"

# Bounds how many Rails parallel test workers a LOCAL full-suite cert spawns, so
# several certs running at once (one per worktree) don't over-subscribe the CPU and
# crash the parallel workers — the SIGSEGV that took out concurrent certs. Each
# cert's share shrinks as more peer certs run.
#
# Plain Ruby: bin/full-suite-check require_relatives it alongside the other bin/lib
# helpers (full_suite_gate, repo_root).
module CertConcurrency
  # Substring that identifies a running full-suite cert in the process list.
  PEER_MARKER = "full-suite-check"

  # A process line carrying the marker that is a REAL cert — the Ruby interpreter
  # (or the script itself) running full-suite-check. This excludes the two lines
  # that carry the marker but aren't certs: the shell that LAUNCHED the cert (the
  # marker rides inside its `-c` eval string) and a search tool grepping the name.
  CERT_PROCESS = %r{\bruby[0-9.]*\b|\A\S*bin/full-suite-check(?:\s|\z)}

  # Cores never handed to test workers — headroom for the OS and the agent.
  RESERVED_CORES = 2

  # Workers for THIS cert: usable cores (all but RESERVED_CORES) split evenly
  # across the certs running right now, never below 1.
  #   worker_cap(cores: 10, peers: 1) => 8   solo — two cores of headroom
  #   worker_cap(cores: 10, peers: 2) => 4   two concurrent certs split it
  #   worker_cap(cores: 4,  peers: 5) => 1   never below one worker
  def self.worker_cap(cores:, peers:)
    usable = cores.to_i - RESERVED_CORES
    [usable / [peers.to_i, 1].max, 1].max
  end

  # Logical processor count; a safe 2 if the platform won't say.
  def self.processor_count
    Etc.nprocessors
  rescue StandardError
    2
  end

  # The `ps` command listing (one process per line), or "" when ps is unavailable —
  # best-effort, so a missing listing just yields a lone-cert cap.
  def self.process_listing
    IO.popen(["ps", "-Ao", "command="], err: File::NULL, &:read).to_s
  rescue StandardError
    ""
  end

  # Running full-suite CERTS, THIS one included, floored at 1. The launcher shell and
  # search tools carry the marker too, so filter to actual cert processes.
  def self.active_peer_certs
    running = process_listing.lines.count do |line|
      line.include?(PEER_MARKER) && line.match?(CERT_PROCESS)
    end
    [running, 1].max
  end

  # The PARALLEL_WORKERS value for this cert's Rails test lane.
  def self.parallel_workers
    worker_cap(cores: processor_count, peers: active_peer_certs)
  end
end
