# frozen_string_literal: true

# [unit] ONE WAY INTO 1PASSWORD: no file under bin/, app/ or lib/ runs `op` outside the
# metered wrapper (bin/lib/op_meter.rb; op_metered in bin/lib/op-meter.sh), so bin/op-reads
# sees every read. Procedure: docs/agents/modules/credential-access.md. Non-comment lines
# are scanned for `op` in argv form (`["op", "read", …]`, `[OP_BIN, "item", …]`) or shell
# form (`op read …`, `"$OP" whoami`). A hit is allowed when the line goes through the
# wrapper, or ALLOWED names it with a reason; an allowance matching nothing fails too.
# "Metered" implies "bounded".
# History: task one-way-into-1password.

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/op_call_scan"

class OpReadsAreBoundedTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # The shapes, the wrappers and the scan live in bin/lib/op_call_scan.rb, shared with
  # the direct-caller ratchet (test/lib/op_direct_callers_ratchet_test.rb).

  # path => [[substring that marks the line, why it may stay, optional regex that
  # must appear within two lines of it (the meter beside an injected or stdin call)]]
  ALLOWED = {
    "bin/lib/agent_harness_probe.rb" => [
      ["OP_SCRIPT = 'op whoami",
       "the harness probe's `op whoami` measures whether the cache daemon answers; it costs no read " \
       "(measured 2026-10-24) and must not be retried, so it stays outside the wrapper"]
    ],
    "bin/lib/domain_register.rb" => [
      ['runner.call(env, ["op", "read", ref])',
       "the default runner on the line above is OpMeter.popen; the seam lets the unit test inject one",
       /OpMeter\.popen/],
      ['raise Abort, "op read #{ref} failed', "error text naming the read that failed"]
    ],
    "bin/gh-app-git-credential" => [
      ["(op item get). $(admin_remedy)", "error text naming the read that failed"]
    ],
    "bin/lib/chrome_profiles.rb" => [
      ["op whoami                       # is the session live?", "help text: commands for the operator"],
      ["op service-account ratelimit    # the daily cap", "help text"],
      ["op document get \#{item.inspect}", "help text"],
      ["op document create <roster.yml>", "help text"]
    ],
    "bin/lib/heroku_ci_key_rotation.rb" => [
      ['metered("read")', "Vault#metered records the call with OpMeter.record (the edit needs stdin)", /metered\("read"\) \{/],
      ['metered("item get")', "same"],
      ['metered("item edit")', "same"]
    ],
    "bin/lib/conductor_host.rb" => [
      ["\"op read '\#{OpVaults.ref", "printed remedy text for the operator of a new host; never executed here"]
    ],
    "bin/lib/local_services.rb" => [
      ["\"$(op read '", "printed remedy text for a missing .env key; never executed here"]
    ]
  }.freeze

  # [path, lineno, line, window] for every unmetered `op` invocation.
  def hits(paths = nil)
    OpCallScan.raw_hits(ROOT, paths || OpCallScan.files(ROOT))
  end

  def allowed?(path, line, window)
    ALLOWED.fetch(path, []).any? { |marker, _why, near| line.include?(marker) && (near.nil? || window.match?(near)) }
  end

  def test_no_file_runs_op_outside_the_metered_wrapper
    raw = hits.reject { |path, _n, line, window| allowed?(path, line, window) }

    assert_empty raw, "these run 1Password's `op` without the meter, so bin/op-reads cannot see them. " \
                      "Use OpMeter.popen (Ruby) or op_metered (shell), per " \
                      "docs/agents/modules/credential-access.md:\n" +
                      raw.map { |p, n, l, _w| "  #{p}:#{n}: #{l}" }.join("\n")
  end

  def test_every_allowance_still_names_a_live_call
    found = hits
    ALLOWED.each do |path, rules|
      rules.each do |marker, _why|
        assert found.any? { |p, _n, l, _w| p == path && l.include?(marker) },
               "#{path}: the allowance #{marker.inspect} matches no op call any more; drop it"
      end
    end
  end

  # The control: the detector must catch each shape it claims to, and pass prose.
  def test_the_detector_catches_each_raw_shape_and_passes_prose
    Dir.mktmpdir do |dir|
      rb = File.join(dir, "raw.rb")
      File.write(rb, <<~RUBY)
        out = IO.popen(["op", "read", ref], &:read)
        Open3.capture3(env, "op", "item", "get", name)
        system(OP_BIN, "x") || IO.popen([OP_BIN, "read", ref])
        SCRIPT = 'op whoami >/dev/null'
        warn "check `op vault list` for the vault"
        OpMeter.popen({}, ["op", "read", ref], via: "ok")
        token = `op read op://v/i/f`.strip
        failing = ("1Password (`op whoami`)" if down)
      RUBY
      sh = File.join(dir, "raw.sh")
      File.write(sh, <<~SH)
        #!/bin/bash
        value="$(op read "$ref")"
        "$OP" whoami >/dev/null
        op_metered "$OP" read "$ref"
        echo "Run 'op signin' first"
      SH
      found = with_root(dir) { hits(%w[raw.rb raw.sh]) }.map { |p, n, _l, _w| [p, n] }

      assert_equal [["raw.rb", 1], ["raw.rb", 2], ["raw.rb", 3], ["raw.rb", 4], ["raw.rb", 7], ["raw.sh", 2], ["raw.sh", 3]], found,
                   "argv, splat, constant-binary, shell-string and backtick forms are caught; metered lines and prose are not"
    end
  end

  # The bare shapes the 2026-10-27 conversion replaced still trip the scan.
  def test_the_shapes_the_first_pin_caught_are_still_caught
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "old.rb"), <<~'RUBY')
        value = IO.popen(["op", "read", ref], err: File::NULL, &:read)
        IO.popen(env, ["op", "read", ref], err: File::NULL, &:read).to_s.strip
        Open3.popen3("op", "read", item) do |stdin, stdout|
        Open3.capture2e({ "OP_CACHE" => "false" }, "op", "whoami")
      RUBY
      assert_equal [1, 2, 3, 4], with_root(dir) { hits(%w[old.rb]) }.map { |_p, n, _l, _w| n }
    end
  end

  private

  def with_root(dir)
    old = ROOT
    self.class.send(:remove_const, :ROOT)
    self.class.const_set(:ROOT, dir)
    yield
  ensure
    self.class.send(:remove_const, :ROOT)
    self.class.const_set(:ROOT, old)
  end
end
