# frozen_string_literal: true

# release-cycle-runs-end-to-end: `bin/release cycle` as a state machine over the
# board's release stage, proven with FAKE steps and a FAKE board. Nothing here runs
# a real prepare, ship, archive, board read, token mint or HTTP request.
#
#   ruby -Itest test/lib/release_cycle_test.rb

require "minitest/autorun"
require "stringio"
require_relative "../../bin/lib/release_cycle"
require_relative "../../app/models/release/devnet_gauntlet"

class ReleaseCycleTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  OWN = "session-own-1234"
  CLEARANCE = "ship it when QA is green"

  # The `test "…"` declaration without Rails: each becomes test_unit_<words>.
  def self.test(name, &block)
    method = "test_#{name.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '')}"
    raise "duplicate test #{method}" if method_defined?(method)

    define_method(method, &block)
  end

  # A scripted board and scripted steps. `snapshots` is consumed one per read (the
  # last one repeats); `steps` maps a step name to a list of [status, output]
  # answers consumed in order (the last repeats).
  class FakeDeps
    attr_reader :calls, :reads, :checked

    def initialize(snapshots:, steps: {}, http: {}, session: OWN, targets: nil)
      @snapshots = snapshots
      @steps = steps.transform_values(&:dup)
      @http = http
      @session = session
      @targets = targets
      @calls = []
      @reads = 0
      @checked = []
      @clock = Time.utc(2026, 10, 28, 20, 0, 0)
    end

    def now = (@clock += 1)
    def session_id = @session

    def snapshot
      @reads += 1
      @snapshots.size > 1 ? @snapshots.shift : @snapshots.first
    end

    def run_step(name, argv)
      @calls << argv
      answers = @steps.fetch(name) { [[0, ""]] }
      answers.size > 1 ? answers.shift : answers.first
    end

    def verify_targets(repos, target)
      return @targets.call(repos, target) if @targets

      [["mcritchie-studio", target == :qa ? "https://qa.example" : "https://prod.example"]]
    end

    def http_status(url)
      @checked << url
      @http.fetch(url, "200")
    end
  end

  def release(state, slug: "rel-x", repos: ["mcritchie-studio"], **extra)
    { "slug" => slug, "state" => state, "repos" => repos }.merge(extra.transform_keys(&:to_s))
  end

  def snap(current: nil, last_shipped: nil, archivable: 0, holders: [], estimate: nil)
    { "current" => current, "last_shipped" => last_shipped, "archivable" => archivable,
      "holders" => holders, "estimate" => estimate }
  end

  def run_cycle(deps, clearance: CLEARANCE, **opts)
    out = StringIO.new
    status = ReleaseCycle::Runner.new(clearance: clearance, deps: deps, out: out, **opts).run
    [status, out.string]
  end

  def step_names(deps) = deps.calls.map(&:first)

  # --- resume from each stage ----------------------------------------------------

  test "[unit] from no active release it runs every act in order, ending in the archive" do
    deps = FakeDeps.new(snapshots: [snap, snap(current: release("assembled")),
                                    snap(last_shipped: release("shipped"), archivable: 3)])
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[prepare ship archive], step_names(deps)
    assert_equal ["https://qa.example/up", "https://qa.example/", "https://prod.example/up", "https://prod.example/"],
                 deps.checked
    %w[1/5 2/5 3/5 4/5 5/5].each { |n| assert_includes out, "▸ #{n}" }
  end

  test "[unit] an assembling release resumes at prepare" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembling")), snap(current: release("assembled"))])
    status, = run_cycle(deps)

    assert_equal 0, status
    assert_equal %w[prepare ship archive], step_names(deps)
  end

  test "[unit] an assembled release resumes at QA verify and never re-runs prepare" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"))])
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[ship archive], step_names(deps)
    assert_includes out, "starting at qa verify"
    refute_includes out, "▸ 1/5"
  end

  test "[unit] a shipped release with an archive owed resumes at prod verify, then archives" do
    deps = FakeDeps.new(snapshots: [snap(last_shipped: release("shipped"), archivable: 4)])
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[archive], step_names(deps)
    assert_equal ["https://prod.example/up", "https://prod.example/"], deps.checked
    assert_includes out, "starting at prod verify"
  end

  test "[unit] prepare that finds nothing to release ends the cycle cleanly, with no ship" do
    deps = FakeDeps.new(snapshots: [snap])
    status, out = run_cycle(deps)

    assert_equal 0, status
    assert_equal %w[prepare], step_names(deps)
    assert_includes out, "nothing to release"
  end

  test "[unit] prepare exiting 0 without an assembled release stops the cycle before ship" do
    deps = FakeDeps.new(snapshots: [snap, snap(current: release("assembling"))])
    status, out = run_cycle(deps)

    assert_equal ReleaseCycle::BOARD_UNREADABLE, status
    assert_equal %w[prepare], step_names(deps)
    assert_includes out, "not assembled"
  end

  # --- a step failure is read, not guessed at --------------------------------------

  test "[unit] a transient GitHub network failure re-runs the step once, then succeeds" do
    deps = FakeDeps.new(snapshots: [snap, snap(current: release("assembled"))],
                        steps: { "prepare" => [[1, "fatal: unable to access: Failed to connect to github.com port 443"],
                                               [0, ""]] })
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[prepare prepare ship archive], step_names(deps)
    assert_includes out, "re-running it once"
  end

  test "[unit] a network failure that recurs fails the cycle after ONE re-run" do
    deps = FakeDeps.new(snapshots: [snap],
                        steps: { "prepare" => [[1, "curl: (28) Timeout was reached"]] })
    status, out = run_cycle(deps)

    assert_equal 1, status
    assert_equal %w[prepare prepare], step_names(deps)
    assert_includes out, "stopped (exit 1)"
  end

  test "[unit] a failure that is not transient is never re-run" do
    deps = FakeDeps.new(snapshots: [snap], steps: { "prepare" => [[1, "✗ merge conflict in app/models/task.rb"]] })
    status, = run_cycle(deps)

    assert_equal 1, status
    assert_equal %w[prepare], step_names(deps)
  end

  test "[unit] each network message the brief names classifies as transient; others do not" do
    ["Failed to connect to github.com port 443 after 75000 ms", "Timeout was reached",
     "Could not resolve host: github.com"].each do |line|
      assert ReleaseCycle.retryable_cause("…\n#{line}\n…"), line
    end
    assert_nil ReleaseCycle.retryable_cause("HTTP 401 Bad credentials")
    assert_nil ReleaseCycle.retryable_cause("")
  end

  test "[unit] a stale-tree refusal from prepare re-runs bare prepare once (the newcomer rides)" do
    stale = "✗ stale tree: `release` does not carry `accepted` in mcritchie-studio — prepare REFUSED"
    deps = FakeDeps.new(snapshots: [snap(current: release("assembling")), snap(current: release("assembled"))],
                        steps: { "prepare" => [[1, stale], [0, ""]] })
    status, = run_cycle(deps)

    assert_equal 0, status
    assert_equal %w[prepare prepare ship archive], step_names(deps)
  end

  # The pattern must match what bin/release.rb actually prints, not a paraphrase.
  test "[unit] the stale-tree pattern matches bin/release.rb's own refusal text" do
    source = File.read(File.join(ROOT, "bin", "release.rb"))
    line = source[/abort!\("stale tree: `#\{RELEASE_BRANCH\}` does not carry `#\{ACCEPTED_BRANCH\}`/]

    assert line, "bin/release.rb no longer prints the stale-tree refusal ReleaseCycle::STALE_TREE reads"
    rendered = line.sub("abort!(\"", "").gsub("\#{RELEASE_BRANCH}", "release").gsub("\#{ACCEPTED_BRANCH}", "accepted")
    assert_match ReleaseCycle::STALE_TREE, rendered
  end

  test "[unit] prepare's gauntlet-red exit (4) stops the cycle with no ship" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembling"))],
                        steps: { "prepare" => [[4, "✗ devnet gauntlet RED at step `conclude`"]] })
    status, = run_cycle(deps)

    assert_equal 4, status
    assert_equal %w[prepare], step_names(deps)
  end

  test "[unit] an assembled Turf release with no green gauntlet runs prepare (which runs it) before ship" do
    turf = release("assembled", repos: ["turf-monster"], gauntlet_required: true, gauntlet_status: nil)
    green = release("assembled", repos: ["turf-monster"], gauntlet_required: true, gauntlet_status: "completed")
    deps = FakeDeps.new(snapshots: [snap(current: turf), snap(current: green)])
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[prepare ship archive], step_names(deps)
    assert_includes out, "devnet gauntlet owed"
  end

  test "[unit] ship refused for the gauntlet re-runs prepare, then ships once more" do
    refusal = "✗ #{Release::DevnetGauntlet.refusal(['turf-monster'])}"
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"))],
                        steps: { "ship" => [[1, refusal], [0, ""]] })
    status, out = run_cycle(deps)

    assert_equal 0, status, out
    assert_equal %w[ship prepare ship archive], step_names(deps)
  end

  test "[unit] a second gauntlet refusal stops the cycle; prepare is re-run only once" do
    refusal = "✗ #{Release::DevnetGauntlet.refusal(['turf-monster'])}"
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"))], steps: { "ship" => [[1, refusal]] })
    status, = run_cycle(deps)

    assert_equal 1, status
    assert_equal %w[ship prepare ship], step_names(deps)
  end

  test "[unit] the gauntlet pattern matches Release::DevnetGauntlet's real refusal" do
    assert ReleaseCycle.gauntlet_refusal?(Release::DevnetGauntlet.refusal(["turf-monster"]))
    refute ReleaseCycle.gauntlet_refusal?("✗ release is 'assembling', not assembled")
  end

  test "[unit] a QA URL that does not answer 200 stops the cycle before ship" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"))], http: { "https://qa.example/" => "503" })
    status, out = run_cycle(deps)

    assert_equal ReleaseCycle::VERIFY_FAILED, status
    assert_empty step_names(deps)
    assert_includes out, "✗ mcritchie-studio https://qa.example/ → 503"
  end

  # --- the two refusals ----------------------------------------------------------

  test "[unit] no clearance refuses before reading the board or running anything" do
    [nil, "", "   "].each do |words|
      deps = FakeDeps.new(snapshots: [snap])
      status, out = run_cycle(deps, clearance: words)

      assert_equal ReleaseCycle::REFUSED, status
      assert_equal 0, deps.reads
      assert_empty deps.calls
      assert_includes out, "Nothing ran"
    end
  end

  test "[unit] a live claim held by another session stands the cycle down" do
    holder = { "role" => "deployer", "release_slug" => "rel-x", "session" => "session-other-9b57", "live" => true,
               "sentence" => "Mawile (steffon, session …9b57) is shipping rel-x." }
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"), holders: [holder])])
    status, out = run_cycle(deps)

    assert_equal ReleaseCycle::STOOD_DOWN, status
    assert_empty deps.calls
    assert_includes out, "Mawile (steffon, session …9b57) is shipping rel-x."
  end

  test "[unit] this session's own claim, or a lapsed foreign one, is a resume, not a collision" do
    mine = { "role" => "assembler", "session" => OWN, "live" => true }
    lapsed = { "role" => "deployer", "session" => "someone-else", "live" => false }
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"), holders: [mine, lapsed])])
    status, = run_cycle(deps)

    assert_equal 0, status
    assert_equal %w[ship archive], step_names(deps)
  end

  # --- what each act is handed ---------------------------------------------------

  test "[unit] ship runs --mode cleared with the clearance verbatim; flags pass through" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"))])
    run_cycle(deps, assume_yes: true, wait_for_1password: 60)
    ship = deps.calls.find { |argv| argv.first == "ship" }

    assert_equal ["ship", "--mode", "cleared", "--clearance", CLEARANCE, "--yes", "--wait-for-1password=60"], ship
    assert_equal ["archive", "--yes"], deps.calls.last, "archive takes no --wait-for-1password (it would refuse it)"
  end

  test "[unit] each stage line carries elapsed time and the DevOps ETA when the board has one" do
    deps = FakeDeps.new(snapshots: [snap(current: release("assembled"), estimate: { "eta" => "2026-10-28T21:30:00Z" })])
    _, out = run_cycle(deps)

    assert_match(/▸ 2\/5 qa verify · \d\d:\d\d M[DS]T · ETA 15:30 MDT \(DevOps estimate\)/, out)
    assert_match(/✓ ship · \d+s \(cycle /, out)
  end

  test "[unit] a board that cannot be read is read once more, then stops with nothing run" do
    deps = FakeDeps.new(snapshots: [nil])
    status, out = run_cycle(deps)

    assert_equal ReleaseCycle::BOARD_UNREADABLE, status
    assert_equal 2, deps.reads
    assert_empty deps.calls
    assert_includes out, "could not read the board"
  end

  # The one execution this file permits: with no clearance the REAL script refuses
  # before any board read, mint or step, so the wiring (dispatch arm, the 1Password
  # flag carried to cycle rather than refused) is proven without a release.
  test "[unit] the script dispatches cycle and refuses without clearance, by execution" do
    require "open3"
    require "rbconfig"
    out, err, status = Open3.capture3({ "RAILS_ENV" => "test" }, RbConfig.ruby, File.join(ROOT, "bin", "release.rb"),
                                      "cycle", "--local", "--wait-for-1password=5")

    assert_equal ReleaseCycle::REFUSED, status.exitstatus, err
    assert_includes out, "cycle refused: no --clearance"
    assert_includes out, "Nothing ran"
  end

  # --- credentials and URLs ------------------------------------------------------

  test "[unit] prepare and archive mint the agent token with GH_APP_ITEM unset" do
    minted = []
    env, ok = ReleaseCycle.step_env("prepare", mint: ->(id, _env) { minted << id; "tok-agent" },
                                               base_env: { "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "sourced-admin" })

    assert ok
    assert_equal ["agent"], minted
    assert_equal({ "OP_CACHE" => "false", "RELEASE_CI_POLL_TIMEOUT" => "3600", "GH_APP_ITEM" => nil,
                   "GH_TOKEN" => "tok-agent" }, env.except(*ReleaseCycle::ADMIN_ONLY_ENV))
    ReleaseCycle::ADMIN_ONLY_ENV.each { |name| assert(env.key?(name) && env[name].nil?, "#{name} must be UNSET") }
    # Pinned to the lanes that own them, so a renamed variable cannot slip past.
    require_relative "../../bin/lib/op_vaults"
    require_relative "../../bin/lib/heroku_token"
    owned = [OpVaults.token_env(:deployer)] + HerokuToken::LANES.values_at(:admin, :applications).flat_map { |l| l[:env] }
    assert_equal owned.sort, ReleaseCycle::ADMIN_ONLY_ENV.sort
  end

  test "[unit] ship mints the deployer token in the admin lane, loading the admin 1Password token" do
    seen = nil
    env, ok = ReleaseCycle.step_env("ship", mint: ->(id, e) { seen = [id, e["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"]]; "tok-d" },
                                            admin_token: -> { "admin-not-a-secret" }, base_env: {})

    assert ok
    assert_equal ["deployer", "admin-not-a-secret"], seen, "the mint must see the admin token it needs"
    assert_equal "github.mcritchie-admin", env["GH_APP_ITEM"]
    assert_equal "tok-d", env["GH_TOKEN"]
  end

  test "[unit] a failed mint UNSETS GH_TOKEN, never leaves it empty" do
    env, ok = ReleaseCycle.step_env("prepare", mint: ->(*) { "" }, base_env: { "RELEASE_CI_POLL_TIMEOUT" => "900" })

    refute ok
    assert env.key?("GH_TOKEN")
    assert_nil env["GH_TOKEN"], "nil unsets the variable in the child; \"\" would make gh refuse every call"
    assert_equal "900", env["RELEASE_CI_POLL_TIMEOUT"], "an operator's own poll budget is kept"
  end

  test "[unit] verify targets: QA and prod URLs per carried app, the hub always, gems skipped" do
    apps = { "mcritchie-studio" => {},
             "turf-monster" => { "prod_deploy" => { "smoke_url" => "https://turf.example" } } }
    envs = { "mcritchie-studio" => { "qa_url" => "https://qa.hub", "production_url" => "https://hub" },
             "turf-monster" => { "qa_url" => "https://qa.turf/", "production_url" => "https://ignored" } }

    qa = ReleaseCycle.verify_targets(%w[turf-monster studio-engine], :qa, app_repos: apps, qa_environments: envs)
    prod = ReleaseCycle.verify_targets(%w[turf-monster], :prod, app_repos: apps, qa_environments: envs)

    assert_equal [["mcritchie-studio", "https://qa.hub"], ["turf-monster", "https://qa.turf"]], qa
    assert_equal [["mcritchie-studio", "https://hub"], ["turf-monster", "https://turf.example"]], prod
  end
end
