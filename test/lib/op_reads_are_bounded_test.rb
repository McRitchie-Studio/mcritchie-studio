# frozen_string_literal: true

# [unit] ONE WAY INTO 1PASSWORD: no file under bin/, app/ or lib/ runs `op`
# outside the metered wrapper (bin/lib/op_meter.rb for Ruby, op_metered in
# bin/lib/op-meter.sh for shell), so bin/op-reads sees every read.
#
# WHY. On 2026-10-31 the account-wide service-account quota (1000 read_writes a
# day) ran out and every agent stalled for about five hours. The meter logged only
# a few hundred successful reads, because a list of callers ran `op` directly and
# nothing recorded them. A spend nobody can attribute has to be re-derived by hand
# every time, which is the defect bin/op-reads exists to end. The procedure:
# docs/agents/modules/credential-access.md.
#
# HOW. Every non-comment line is scanned for an `op` invocation in argv form
# (`["op", "read", …]`, `[OP_BIN, "item", …]`) or shell form (`op read …`,
# `"$OP" whoami`). A hit is allowed when the same line goes through the wrapper,
# or when ALLOWED below names it with a reason. An allowance that matches nothing
# fails too: an exemption must keep measuring the thing it exempts.
#
# HISTORY. This file began (2026-10-27) as a Ruby-only pin on a literal "op" as the
# first argument of IO.popen, Open3, system, spawn or exec: every `op` call had hung
# for two hours and a bare call waited with the daemon. It missed shell strings,
# `op_bin` variables and BoundedCommand.capture3, so the unmetered callers above
# passed it. The scan now covers bin/, app/ and lib/, shell and Ruby, and asks
# "metered", which implies "bounded": both halves of the wrapper bound every attempt.
#
#   ruby -Itest test/lib/op_reads_are_bounded_test.rb

require "minitest/autorun"
require "tmpdir"

class OpReadsAreBoundedTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCANNED = %w[bin app lib].freeze

  # The wrapper itself is the one place a raw `op` belongs.
  WRAPPERS = %w[bin/lib/op_meter.rb bin/lib/op-meter.sh].freeze

  # A line that goes through the wrapper is metered.
  METERED = /OpMeter\.popen|op_metered\b/

  SUBCOMMANDS = %w[read item inject whoami vault document signin service-account run].freeze
  # `run` collides with `gh run` when the binary is a variable, so a variable binary
  # counts only with an op-only subcommand; a literal "op" counts with any.
  VAR_SUBCOMMANDS = (SUBCOMMANDS - %w[run]).freeze
  LITERAL_ARGV = /["']op["']\s*,\s*(?:["'](?:#{SUBCOMMANDS.join('|')})["']|\*)/
  VAR_ARGV = /\[\s*(?:OP|OP_BIN|@?op_bin(?:\([^)]*\))?|@?bin)\s*,\s*["'](?:#{VAR_SUBCOMMANDS.join('|')})["']/
  # Shell form. In a shell script a command starts a line or follows a separator; in
  # Ruby it can only run from inside a string, so it must open the string (or a
  # `$(` inside one). Prose in backticks ("check `op vault list`") is neither.
  SHELL_BIN = %r{(?:op|"?\$\{?OP(?:_BIN)?\}?"?|/opt/homebrew/bin/op)}
  SHELL_FORM = /(?:\A|[;&|(]|\$\(|\A\s+)\s*#{SHELL_BIN}\s+(?:#{SUBCOMMANDS.join('|')})\b/
  RUBY_STRING_FORM = /(?:\A\s*|[(,=]\s*|\$\()["']?(?:op)\s+(?:#{SUBCOMMANDS.join('|')})\b/
  # A Ruby backtick or %x runs a shell too. Only where an expression starts (a line,
  # an assignment, a return): prose quotes `op whoami` mid-sentence, and that passes.
  RUBY_BACKTICK_FORM = /(?:\A\s*|=\s*|\breturn\s+)(?:`|%x[({\[])\s*op\s+(?:#{SUBCOMMANDS.join('|')})\b/

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
    "app/services/gmail/credentials.rb" => [
      ['"op", "read", item,', "meter_op_read records it on the next line; the read keeps its own single bound",
       /meter_op_read\(status\)/]
    ],
    "app/services/workspace/credentials.rb" => [
      ['"op", "read", item,', "meter_op_read records it on the next line; the read keeps its own single bound",
       /meter_op_read\(status\)/]
    ],
    "bin/lib/conductor_host.rb" => [
      ["\"op read '\#{OpVaults.ref", "printed remedy text for the operator of a new host; never executed here"]
    ],
    "bin/lib/local_services.rb" => [
      ["\"$(op read '", "printed remedy text for a missing .env key; never executed here"]
    ]
  }.freeze

  def files
    SCANNED.flat_map { |dir| Dir.glob(File.join(ROOT, dir, "**", "*")) }
           .select { |p| File.file?(p) && !File.symlink?(p) }
           .map { |p| p.delete_prefix("#{ROOT}/") }
           .reject { |p| WRAPPERS.include?(p) || p.start_with?("app/assets/", "bin/node_modules/") }
           .select { |p| p.end_with?(".rb", ".sh", ".rake") || shebang?(p) }
  end

  def shebang?(path)
    File.open(File.join(ROOT, path), &:gets).to_s.start_with?("#!")
  rescue ArgumentError, SystemCallError
    false
  end

  def ruby?(path)
    path.end_with?(".rb", ".rake") || File.open(File.join(ROOT, path), &:gets).to_s.include?("ruby")
  end

  # [path, lineno, line] for every unmetered `op` invocation.
  def hits(paths = files)
    paths.flat_map do |path|
      ruby = ruby?(path)
      all = File.readlines(File.join(ROOT, path)).map { |l| l.scrub.chomp }
      all.each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?("#") || line.match?(METERED)

        found = line.match?(LITERAL_ARGV) || line.match?(VAR_ARGV) ||
                (ruby ? line.match?(RUBY_STRING_FORM) || line.match?(RUBY_BACKTICK_FORM) : line.match?(SHELL_FORM))
        [path, i + 1, line.strip, all[[i - 2, 0].max..(i + 2)].join("\n")] if found
      end
    end
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
