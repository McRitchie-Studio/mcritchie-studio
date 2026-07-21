# frozen_string_literal: true

# Integration test: CertDatabaseReaper against a REAL Postgres cluster. It proves
# the two behaviours a synthetic lease directory cannot — that a real dropdb fires
# for a dead owner (AC1) and does NOT fire for a live one (AC2) — with real
# databases and the reaper's real liveness check (process_alive?), not an injected
# one. Skips when no Postgres connection URL is reachable (a local shell without
# one); CI sets DATABASE_URL, so the real proof runs there.
#
# Run directly:  DATABASE_URL=postgresql://localhost/postgres ruby -Itest test/lib/cert_database_reaper_integration_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "securerandom"
require "uri"
require "open3"
require_relative "../support/cert_database_reaper"

class CertDatabaseReaperIntegrationTest < Minitest::Test
  BASE = "mcritchie_studio_test"

  def setup
    @template = pg_template_url
    skip "no DATABASE_URL/TEST_DATABASE_URL to reach Postgres" if @template.empty?

    @uri = URI.parse(@template)
    @env = pg_conn_env(@uri)
    @dir = Dir.mktmpdir("cert-db-reaper-int")
    @created = []
  end

  def teardown
    @created.each { |name| system(@env, "dropdb", "--if-exists", name, out: File::NULL, err: File::NULL) }
    FileUtils.rm_rf(@dir) if @dir
  end

  # AC1: a hard-killed run's database is gone after the reaper runs.
  def test_reaps_a_dead_owners_real_database
    name = ephemeral_name
    createdb(name)
    dead = fork { exit! }
    Process.wait(dead) # reap the zombie so the pid is provably gone
    CertDatabaseReaper.register(name, dir: @dir, pid: dead)

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE, drop: dropper)

    refute db_exists?(name), "the reaper must drop a dead owner's stranded database"
    assert_includes result[:reaped], name
    assert_empty Dir.glob(File.join(@dir, "*.json")), "the lease must be cleared once the DB is dropped"
  end

  # AC2: a live run's database survives the reaper untouched.
  def test_keeps_a_live_owners_real_database
    name = ephemeral_name
    createdb(name)
    CertDatabaseReaper.register(name, dir: @dir, pid: Process.pid) # this process is alive

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE, drop: dropper)

    assert db_exists?(name), "the reaper must NOT drop a database a live run still owns"
    assert_includes result[:skipped], name
  end

  private

  def dropper
    ->(name) { system(@env, "dropdb", "--if-exists", name, out: File::NULL, err: File::NULL) }
  end

  def ephemeral_name
    name = "#{BASE}_reaperspec_#{SecureRandom.hex(4)}"
    @created << name
    name
  end

  def createdb(name)
    assert system(@env, "createdb", name, out: File::NULL, err: File::NULL), "createdb #{name} failed"
  end

  def db_exists?(name)
    out, _err, status = Open3.capture3(
      @env, "psql", "-Atqc",
      "SELECT 1 FROM pg_database WHERE datname = '#{name}'", "postgres"
    )
    status.success? && out.strip == "1"
  end

  def pg_template_url
    url = ENV["DATABASE_URL"].to_s
    url = ENV["TEST_DATABASE_URL"].to_s if url.strip.empty?
    url.strip
  end

  def pg_conn_env(uri)
    env = { "PATH" => ENV.fetch("PATH", "") }
    env["PGHOST"] = uri.host if uri.host && !uri.host.empty?
    env["PGPORT"] = uri.port.to_s if uri.port
    env["PGUSER"] = uri.user if uri.user && !uri.user.empty?
    env["PGPASSWORD"] = uri.password if uri.password && !uri.password.empty?
    env
  end
end
