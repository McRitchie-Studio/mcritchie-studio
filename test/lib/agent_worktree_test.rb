# frozen_string_literal: true

# Standalone test for bin/agent-worktree's pure port-allocation helpers. Mirrors
# test/lib/release_cli_test.rb: it `load`s the script in a clean subprocess so the
# guarded dispatch (`if $PROGRAM_NAME == __FILE__`) never fires, redefines the
# I/O-bound helpers (allocated_ports / port_listening? / port_pid / process_cwd)
# as stubs, and exercises the real allocation + adoption-guard logic. Run directly:
#   ruby -Itest test/lib/agent_worktree_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "open3"

class AgentWorktreeTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-worktree", __dir__)

  # How many times to re-spawn a check whose subprocess produced no usable output.
  # See run_in_script for why a deterministic computation is safe to retry.
  SUBPROCESS_ATTEMPTS = 3

  # Load the script (dispatch suppressed by its main guard), run `body`, return
  # the printed value.
  #
  # The COMPUTATION here is deterministic — every check stubs the I/O helpers and
  # exercises pure allocation logic over the static APP_OVERRIDES/satellites config,
  # so a correct run ALWAYS prints the same thing. The PROCESS SPAWN is not: under
  # CI's parallel-fork harness a child occasionally got reaped/killed before it
  # flushed stdout, and the old helper discarded both stderr (`err: File::NULL`) and
  # the exit status, so that transient surfaced as a bare, undiagnosable `Actual: ""`
  # (the flake this test was named for).
  #
  # Hardening, both halves:
  #   * Open3.capture3 blocking-reads stdout AND stderr and waits for the child to
  #     exit, so there is no early-read / unflushed-output race.
  #   * Because the output is deterministic, a transient empty/failed spawn is
  #     RETRIED up to SUBPROCESS_ATTEMPTS times. A real logic error fails every
  #     attempt (deterministically), so the retry cannot mask a genuine regression —
  #     it only absorbs the non-deterministic spawn hiccup.
  #   * If every attempt yields no usable output it FLUNKS with the captured
  #     exit/signal + stderr, so the empty-output mode can never again recur
  #     silently. (rubygems "already initialized" warnings land on the child's
  #     stderr but are ignored on success — we only surface stderr when flunking.)
  def run_in_script(body)
    script = "load #{BIN.inspect}\n#{body}"
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      out, err, status = Open3.capture3("ruby", "-e", script)
      return out.strip if status.success? && !out.strip.empty?

      last = { out: out, err: err, status: status }
    end

    status = last[:status]
    flunk <<~MSG
      agent-worktree subprocess produced no usable output after #{SUBPROCESS_ATTEMPTS} attempts.
        exit=#{status.exitstatus.inspect} signal=#{status.termsig.inspect}
        stdout=#{last[:out].inspect}
        stderr:
      #{last[:err].to_s.gsub(/^/, "    ")}
    MSG
  end

  # --- allocate_port: reserved_ports are skipped, not just live listeners ------

  def test_allocate_port_skips_reserved_ports
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      app = { "primary_port" => 3000, "range_end" => 3099, "range_start" => 3000, "reserved_ports" => [3020] }
      print allocate_port(app)
    RUBY
    assert_equal "3021", out, "3001-3019 used + 3020 reserved => next free is 3021"
  end

  def test_allocate_port_uses_the_port_when_not_reserved
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      app = { "primary_port" => 3000, "range_end" => 3099, "range_start" => 3000, "reserved_ports" => [] }
      print allocate_port(app)
    RUBY
    assert_equal "3020", out, "control: without the reservation 3020 is allocated"
  end

  # --- own_stack_on_port?: the foreign-adoption guard -------------------------

  def test_own_stack_true_when_listener_cwd_is_the_worktree
    out = run_in_script(<<~RUBY)
      def port_pid(_p); "12345"; end
      def process_cwd(_pid); "/Users/alex/projects/mcritchie-studio/.worktrees/foo"; end
      print own_stack_on_port?(3020, "/Users/alex/projects/mcritchie-studio/.worktrees/foo")
    RUBY
    assert_equal "true", out
  end

  def test_own_stack_false_for_a_foreign_listener
    out = run_in_script(<<~RUBY)
      def port_pid(_p); "12345"; end
      def process_cwd(_pid); "/Users/alex/projects/rolio"; end
      print own_stack_on_port?(3020, "/Users/alex/projects/mcritchie-studio/.worktrees/foo")
    RUBY
    assert_equal "false", out, "a rolio process on the port is not this worktree's stack"
  end

  def test_own_stack_false_when_port_is_free
    out = run_in_script(<<~RUBY)
      def port_pid(_p); ""; end
      print own_stack_on_port?(3020, "/x")
    RUBY
    assert_equal "false", out
  end

  # --- integration: the REAL mcritchie config carries the reservation through
  #     the merge, and allocate_port honours it end-to-end ----------------------

  def test_mcritchie_config_reserves_3020_through_the_real_merge
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      app = app_for("mcritchie-studio") # real APP_OVERRIDES -> merge -> config
      print [app["reserved_ports"], allocate_port(app)].inspect
    RUBY
    assert_equal "[[3020], 3021]", out, "rolio's 3020 is reserved in the real config and skipped"
  end

  # --- regression: the silent empty-output flake --------------------------------
  #
  # A subprocess that produces NO usable output must fail LOUD with its stderr
  # surfaced — it must never slip through as a bare `Actual: ""` (how the original
  # CI flake masqueraded, because the old helper discarded stderr + exit status).
  # We force that mode deterministically: a body that writes to stderr and exits
  # nonzero on every attempt. The old IO.popen(err: File::NULL) helper would return
  # "" silently (no raise) and fail THIS assertion; the hardened helper flunks with
  # the stderr included.
  def test_run_in_script_flunks_loudly_when_subprocess_yields_no_output
    error = assert_raises(Minitest::Assertion) do
      run_in_script("STDERR.puts 'forced-subprocess-failure'; exit 1")
    end
    assert_match(/forced-subprocess-failure/, error.message,
                 "the swallowed subprocess stderr must surface in the failure message")
    assert_match(/no usable output/, error.message)
  end
end
