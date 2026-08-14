# frozen_string_literal: true

# Coverage for test/support/outbound_seams.rb — the network floor itself.
# Standalone, like the harnesses it protects:
#   ruby -Itest test/lib/outbound_seams_test.rb
#
# THE POINT OF THIS FILE. The floor's whole value is that it holds for harnesses
# that never heard of it, and that is a claim about a CHILD PROCESS's environment,
# which no amount of reading the module can settle. So every test below spawns a
# real child and asks it what it sees. Two of them are written specifically to go
# red on the mistakes that were actually available when the floor was written:
# arming with `||=` (a no-op in any shell that already exports the production
# board), and treating the floor as opt-in (which buys nothing in the files that
# most need it).

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../support/session_env"

class OutboundSeamsTest < Minitest::Test
  SUPPORT = File.expand_path("../support", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)

  # A fresh child that loads the floor the way a test file does, then prints what
  # it resolved. `ambient` is the environment the child STARTS with — the operator's
  # shell, in effect.
  def resolved_in_child(var, ambient = {})
    script = "require \"support/session_env\"; print ENV[#{var.inspect}].to_s"
    out, err, status = Open3.capture3(ambient, RbConfig.ruby, "-I#{TEST_ROOT}", "-e", script)
    assert status.success?, "child failed: #{err}"
    out
  end

  # THE ENFORCEMENT CLAIM. A harness that builds its child env with a bare
  # SessionEnv.neutralized — which is most of them, and none of which mention this
  # module — must still get a child that cannot reach the board.
  def test_unit_an_unadopting_harness_still_gets_a_pinned_child
    out, err, status = Open3.capture3(
      SessionEnv.neutralized, RbConfig.ruby, "-e", 'print ENV["TASK_API_BASE"].to_s'
    )

    assert status.success?, err
    assert_equal OutboundSeams::UNROUTABLE, out,
                 "a child spawned through the PLAIN session scrub inherited #{out.inspect} as its " \
                 "board. If that is https://mcritchie.studio, every unadopting harness in the " \
                 "suite is writing to production — which is the defect this floor exists to close, " \
                 "and adopting it file-by-file would leave it open in exactly the files nobody " \
                 "audited."
  end

  # THE ARMING OPERATOR. `||=` reads as the polite choice and is a NO-OP here: an
  # agent shell exports ATOMIC_CAPTURE_URL=https://mcritchie.studio for its own
  # narration, so keeping the ambient value keeps PRODUCTION. Measured, not
  # imagined — it is what this machine's shell was doing when the floor was built.
  def test_integration_the_floor_overrides_a_production_value_already_in_the_environment
    assert_equal OutboundSeams::UNROUTABLE,
                 resolved_in_child("ATOMIC_CAPTURE_URL",
                                   "ATOMIC_CAPTURE_URL" => "https://mcritchie.studio"),
                 "the floor deferred to the ambient value. That is the `||=` failure: in the shell " \
                 "this suite actually runs in, the ambient value IS the production board, so " \
                 "deferring to it arms nothing."
    assert_equal OutboundSeams::UNROUTABLE,
                 resolved_in_child("TASK_API_BASE", "TASK_API_BASE" => "https://mcritchie.studio")
  end

  # The deliberate live run stays possible, and stays EXPLICIT.
  def test_integration_the_opt_out_releases_the_floor
    assert_equal "https://mcritchie.studio",
                 resolved_in_child("TASK_API_BASE",
                                   "TASK_API_BASE" => "https://mcritchie.studio",
                                   "OUTBOUND_SEAMS" => "off")
  end

  # THE TOKEN BROKER. This is the pin that stops a leaked `gh` refusal from
  # reaching 1Password and minting a real App installation token.
  # (Asserted by SHAPE, not by equality: the child builds its own stub directory,
  # so the paths differ by construction. What must hold is that it is a sealed stub
  # and NOT the real broker, which is the thing that reaches 1Password.)
  def test_unit_the_token_broker_is_sealed_for_every_child
    resolved = resolved_in_child("GH_AUTH_TOKEN_BIN")

    assert resolved.end_with?("/gh-token"), "expected a gh-token broker path, got #{resolved.inspect}"
    assert_includes resolved, "outbound-seams",
                    "the child resolved #{resolved.inspect} as its token broker. Anything outside " \
                    "the seal is the REAL bin/gh-token, which shells `op read` against live " \
                    "1Password and mints a production App installation token."
    refute_equal File.expand_path("../../bin/gh-token", __dir__), resolved
  end

  # The stubs must actually RECORD, or every receipt assertion built on them is
  # vacuous — a green that proves nothing, which is the failure mode this whole
  # change is about.
  def test_unit_a_sealed_command_records_its_argv_and_refuses
    OutboundSeams.reset!
    env = OutboundSeams.env
    _out, _err, status = Open3.capture3(env, OutboundSeams.stub("gh"), "pr", "view", "https://example/pull/1")

    assert_not_predicate status, :success?
    assert_includes OutboundSeams.calls_to("gh"), "gh pr view https://example/pull/1"
  end

  # An empty body is load-bearing, not incidental: GhAuthRetry classifies a refusal
  # by its TEXT, and an auth-shaped one arms the mint. A stub that printed "gh: not
  # authenticated" would seal the call and trigger the credential chain anyway.
  def test_unit_the_refusal_is_not_auth_shaped
    out, err, = Open3.capture3(OutboundSeams.env, OutboundSeams.stub("gh"), "pr", "list")

    assert_empty "#{out}#{err}".strip,
                 "the seal printed something. GhAuthRetry::AUTH_FAILURE matches on wording, so any " \
                 "credential-flavoured text here re-arms the 1Password mint the seal exists to stop."
  end

  def test_unit_env_lets_the_caller_override_any_pin
    env = OutboundSeams.env("TASK_API_BASE" => "http://127.0.0.1:4242")

    assert_equal "http://127.0.0.1:4242", env["TASK_API_BASE"]
    assert_nil env["CLAUDE_CODE_SESSION_ID"], "the session scrub must survive an override"
  end

  def assert_not_predicate(object, predicate, message = nil)
    refute object.public_send(predicate), message
  end
end
