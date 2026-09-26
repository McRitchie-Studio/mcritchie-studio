# frozen_string_literal: true

# [unit] HerokuCiKeyRotation::Runner — the order of a Heroku CI key rotation and
# every guard on it, driven through in-memory fakes of Heroku, 1Password and
# GitHub. Nothing here touches a network or a real credential.
#
#   ruby -Itest test/lib/heroku_ci_key_rotation_test.rb

require "minitest/autorun"
require "stringio"
require "time"
require_relative "../../bin/lib/heroku_ci_key_rotation"

class HerokuCiKeyRotationTest < Minitest::Test
  R = HerokuCiKeyRotation
  ADMIN_KEY = "HRKU-admin-key-000000000000000000000000000000000000000000000000000"
  OLD_KEY = "HRKU-old-ci-key-11111111111111111111111111111111111111111111111111"
  NEW_KEY = "HRKU-new-ci-key-22222222222222222222222222222222222222222222222222"
  OLD_ID = "d976c7b8-0000-0000-0000-000000000001"
  NEW_ID = "aaaaaaaa-0000-0000-0000-000000000002"
  SHAS = { "mcritchie-studio-qa" => "a" * 40, "mcritchie-studio" => "b" * 40 }.freeze
  NOW = Time.utc(2026, 9, 26, 18, 0, 0)

  # Every fake appends to one shared event list, so ORDER is observable.
  class FakeHeroku
    attr_accessor :live, :old_token, :revoked

    def initialize(events)
      @events = events
      @live = SHAS.dup
      @old_token = OLD_KEY
      @revoked = []
    end

    def account_email(key)
      @events << [:heroku_account, key == ADMIN_KEY ? :admin : :other]
      raise R::Abort, "HTTP 401 revoked" if key == OLD_KEY && @revoked.include?(OLD_ID)

      "alex@mcritchie.studio"
    end

    def authorization(_key, id)
      @events << [:heroku_authorization, id]
      { id: id, description: "heroku.studio.applications", scope: %w[identity read-protected], token: @old_token }
    end

    def create_authorization(_key, description:, scope:)
      @events << [:create_authorization, description, scope]
      { id: NEW_ID, token: NEW_KEY }
    end

    def revoke_authorization(_key, id)
      @events << [:revoke, id]
      @revoked << id
      {}
    end

    def live_commit(_key, app) = @live.fetch(app)

    def key_live?(key)
      account_email(key)
      true
    rescue R::Abort
      false
    end
  end

  class FakeVault
    attr_reader :store

    def initialize(events)
      @events = events
      @store = { "credential" => OLD_KEY, "authorization-id" => OLD_ID }
    end

    def read(field) = @store.fetch(field)

    def write(fields)
      @events << [:vault_write, fields.fetch("authorization-id")]
      @store.merge!(fields)
    end
  end

  class FakeGitHub
    attr_accessor :conclusions, :in_flight

    def initialize(events, clock)
      @events = events
      @clock = clock
      @runs = Hash.new { |h, k| h[k] = [{ "databaseId" => 100, "status" => "completed", "event" => "workflow_dispatch" }] }
      @conclusions = Hash.new("success")
      @in_flight = Hash.new(0)
      @secrets = {}
    end

    def secret_updated_at(env) = (@secrets[env] || Time.utc(2026, 9, 1)).iso8601

    def set_secret(env, value)
      @events << [:set_secret, env, value == NEW_KEY ? :new : :old]
      @secrets[env] = @clock.call
    end

    def runs(workflow)
      busy = Array.new(@in_flight[workflow]) { { "databaseId" => 1, "status" => "in_progress", "event" => "push" } }
      @runs[workflow] + busy
    end

    def dispatch(workflow, sha)
      @events << [:dispatch, workflow, sha]
      # Ids are unique ACROSS workflows, as GitHub's are, so a run id names one workflow.
      id = @runs.values.flatten.map { |r| r["databaseId"] }.max + 1
      @runs[workflow] << { "databaseId" => id, "status" => "completed", "event" => "workflow_dispatch",
                           "workflow" => workflow }
    end

    def run(id)
      wf = @runs.find { |_, rs| rs.any? { |r| r["databaseId"] == id } }&.first
      { "status" => "completed", "conclusion" => @conclusions[wf] }
    end
  end

  def setup
    @events = []
    @out = StringIO.new
    clock = -> { NOW }
    @heroku = FakeHeroku.new(@events)
    @vault = FakeVault.new(@events)
    @github = FakeGitHub.new(@events, clock)
    @runner = R::Runner.new(heroku: @heroku, vault: @vault, github: @github, admin_key: ADMIN_KEY,
                            out: @out, poll_seconds: 0, clock: clock, sleeper: ->(_) { })
  end

  MUTATIONS = %i[create_authorization vault_write set_secret dispatch revoke].freeze

  def mutations = @events.select { |e| MUTATIONS.include?(e.first) }

  def assert_no_secret_printed
    [ADMIN_KEY, OLD_KEY, NEW_KEY].each { |s| refute_includes @out.string, s }
  end

  def test_dry_run_plans_every_step_in_order_and_mutates_nothing
    @runner.call(dry_run: true)

    assert_empty mutations, "a dry run must mint, write, dispatch and revoke nothing"
    plan = @out.string[/== plan.*/m]
    positions = %w[mint store set prove revoke].map { |step| plan.index(/^\s+[\d.]+ #{step}\b/) }
    refute_includes positions, nil, plan
    assert_equal positions.sort, positions, "the plan must read mint, store, set, prove, revoke"
    assert_includes plan, "sha=#{SHAS['mcritchie-studio-qa']}"
    assert_includes plan, "sha=#{SHAS['mcritchie-studio']}"
    assert_no_secret_printed
  end

  def test_a_full_run_goes_mint_store_set_prove_revoke
    @runner.call(dry_run: false)

    assert_equal [
      [:create_authorization, "heroku.studio.applications (rotated 2026-09-26 by bin/rotate-heroku-ci-key)",
       %w[identity read-protected]],
      [:vault_write, NEW_ID],
      [:set_secret, "qa", :new],
      [:set_secret, "production", :new],
      [:dispatch, "qa-deploy.yml", SHAS["mcritchie-studio-qa"]],
      [:dispatch, "prod-deploy.yml", SHAS["mcritchie-studio"]],
      [:revoke, OLD_ID]
    ], mutations
    assert_equal NEW_KEY, @vault.store["credential"]
    assert_equal NEW_ID, @vault.store["authorization-id"]
    assert_includes @out.string, "HEROKU_STUDIO_APPLICATIONS_API_KEY"
    assert_no_secret_printed
  end

  # A failed proof must leave the world as it found it and NEVER revoke the old key.
  def test_a_failed_proof_rolls_back_and_keeps_the_old_key
    @github.conclusions["prod-deploy.yml"] = "failure"

    err = assert_raises(R::Abort) { @runner.call(dry_run: false) }

    assert_match(/rolled back/, err.message)
    refute_includes mutations, [:revoke, OLD_ID], "the old authorization must survive a failed proof"
    assert_includes mutations, [:revoke, NEW_ID], "the new authorization is revoked on rollback"
    assert_includes mutations, [:set_secret, "qa", :old]
    assert_includes mutations, [:set_secret, "production", :old]
    assert_equal OLD_KEY, @vault.store["credential"]
    assert_equal OLD_ID, @vault.store["authorization-id"]
    assert_no_secret_printed
  end

  # A failed restore leaves that secret on the NEW key: the new authorization must stay live.
  def test_a_failed_restore_keeps_the_new_authorization_live
    @github.conclusions["prod-deploy.yml"] = "failure"
    @github.define_singleton_method(:set_secret) do |env, value|
      raise R::Abort, "HTTP 401 Bad credentials" if value == OLD_KEY && env == "production"

      super(env, value)
    end

    assert_raises(R::Abort) { @runner.call(dry_run: false) }

    refute_includes mutations, [:revoke, NEW_ID], "production still holds the new key"
    refute_includes mutations, [:revoke, OLD_ID]
    assert_includes @out.string, "NOT revoking the new authorization"
  end

  # A non-Abort failure after the mint (a dropped connection) must roll back too.
  def test_a_network_error_mid_proof_still_rolls_back
    @github.define_singleton_method(:dispatch) { |*| raise Errno::ECONNRESET }

    assert_raises(R::Abort) { @runner.call(dry_run: false) }

    assert_includes mutations, [:revoke, NEW_ID]
    assert_equal OLD_KEY, @vault.store["credential"]
  end

  # If the vault's authorization-id names a different key, revoking it would kill
  # something else. Refuse before minting anything.
  def test_a_vault_id_that_does_not_match_its_key_refuses_before_the_mint
    @heroku.old_token = "HRKU-some-other-key"

    assert_raises(R::Abort) { @runner.call(dry_run: true) }
    assert_empty mutations
  end

  # A no-op deploy queued behind a real one would roll production back.
  def test_a_deploy_in_flight_refuses_in_preflight
    @github.in_flight["prod-deploy.yml"] = 1

    err = assert_raises(R::Abort) { @runner.call(dry_run: false) }

    assert_match(/in flight/, err.message)
    assert_empty mutations
  end

  def test_an_app_that_moved_since_preflight_is_not_dispatched
    heroku = @heroku
    @github.define_singleton_method(:set_secret) do |env, value|
      super(env, value)
      heroku.live["mcritchie-studio-qa"] = "c" * 40
    end

    assert_raises(R::Abort) { @runner.call(dry_run: false) }

    refute(mutations.any? { |e| e.first == :dispatch }, "a moved app must not get an old SHA pushed at it")
    refute_includes mutations, [:revoke, OLD_ID]
  end

  def test_an_old_key_that_still_answers_after_revoke_fails_loudly
    @heroku.define_singleton_method(:key_live?) { |_key| true }

    err = assert_raises(R::Abort) { @runner.call(dry_run: false) }

    assert_match(/still authenticates/, err.message)
  end

  def test_digest_refuses_an_empty_value
    assert_raises(R::Abort) { R.digest("") }
    assert_equal R.digest("x"), R.digest("x")
    refute_equal R.digest("x"), R.digest("y")
  end

  def test_redact_scrubs_every_known_secret
    assert_equal "a [REDACTED] b [REDACTED]", R.redact("a #{OLD_KEY} b #{NEW_KEY}", [OLD_KEY, NEW_KEY, nil, ""])
  end
end
