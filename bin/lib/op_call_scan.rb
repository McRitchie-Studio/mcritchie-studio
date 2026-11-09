# frozen_string_literal: true

# OpCallScan — which files in a tree run 1Password's `op` themselves. A static
# scan: it reads files and runs nothing (no `op`, no subprocess).
#
# TWO READERS, ONE DETECTOR.
#   * test/lib/op_reads_are_bounded_test.rb: no file runs `op` OUTSIDE the
#     metered wrapper (#raw_hits; the test keeps its own reasoned allowances).
#   * test/lib/op_direct_callers_ratchet_test.rb and `bin/op-reads --ratchet`:
#     every file that runs `op` AT ALL, metered or not (#direct_callers), must be
#     on the allowlist in config/op_direct_callers.yml. A new direct caller fails
#     the repo-ratchets lane of bin/fast-check (bin/lib/ci_guard_lanes.rb) and CI.
# The shapes live here once, so the two guards cannot drift apart.
#
# A DIRECT CALLER is a file that starts `op` itself: through OpMeter.popen or
# op_metered (the metered wrapper), or in a raw shape the bounded test allows with
# a reason. A file that only asks a purpose-built client (bin/secret, bin/gh-token,
# SoulSecrets, HerokuToken) is not one. That is the point: the allowlist shrinks
# as callers move behind those clients, and it may not grow without a reviewer
# seeing a reason. Doc: docs/agents/modules/credential-access.md.
#
# Ruby 2.6 syntax (the bin/ tree runs under system Ruby in places).
module OpCallScan
  SCANNED = %w[bin app lib].freeze

  # The wrapper itself is the one place a raw `op` belongs; it is not a caller.
  # This file names the shapes, so it is not one either.
  WRAPPERS = %w[bin/lib/op_meter.rb bin/lib/op-meter.sh bin/lib/op_call_scan.rb].freeze

  # A line that goes through the wrapper is metered.
  METERED = /OpMeter\.popen|op_metered\b/.freeze

  SUBCOMMANDS = %w[read item inject whoami vault document signin service-account run].freeze
  # `run` collides with `gh run` when the binary is a variable, so a variable binary
  # counts only with an op-only subcommand; a literal "op" counts with any.
  VAR_SUBCOMMANDS = (SUBCOMMANDS - %w[run]).freeze
  LITERAL_ARGV = /["']op["']\s*,\s*(?:["'](?:#{SUBCOMMANDS.join('|')})["']|\*)/.freeze
  VAR_ARGV = /\[\s*(?:OP|OP_BIN|@?op_bin(?:\([^)]*\))?|@?bin)\s*,\s*["'](?:#{VAR_SUBCOMMANDS.join('|')})["']/.freeze
  # Shell form. In a shell script a command starts a line or follows a separator; in
  # Ruby it can only run from inside a string, so it must open the string (or a
  # `$(` inside one). Prose in backticks ("check `op vault list`") is neither.
  SHELL_BIN = %r{(?:op|"?\$\{?OP(?:_BIN)?\}?"?|/opt/homebrew/bin/op)}.freeze
  SHELL_FORM = /(?:\A|[;&|(]|\$\(|\A\s+)\s*#{SHELL_BIN}\s+(?:#{SUBCOMMANDS.join('|')})\b/.freeze
  RUBY_STRING_FORM = /(?:\A\s*|[(,=]\s*|\$\()["']?(?:op)\s+(?:#{SUBCOMMANDS.join('|')})\b/.freeze
  # A Ruby backtick or %x runs a shell too. Only where an expression starts (a line,
  # an assignment, a return): prose quotes `op whoami` mid-sentence, and that passes.
  RUBY_BACKTICK_FORM = /(?:\A\s*|=\s*|\breturn\s+)(?:`|%x[({\[])\s*op\s+(?:#{SUBCOMMANDS.join('|')})\b/.freeze

  module_function

  # Every scannable file under +root+ (relative paths): Ruby, shell, rake, or a
  # script with a shebang. The wrappers, assets and node_modules are left out.
  def files(root)
    SCANNED.flat_map { |dir| Dir.glob(File.join(root, dir, "**", "*")) }
           .select { |p| File.file?(p) && !File.symlink?(p) }
           .map { |p| p.delete_prefix("#{root}/") }
           .reject { |p| WRAPPERS.include?(p) || p.start_with?("app/assets/", "bin/node_modules/") }
           .select { |p| p.end_with?(".rb", ".sh", ".rake") || shebang?(root, p) }
           .sort
  end

  def shebang?(root, path)
    File.open(File.join(root, path), &:gets).to_s.start_with?("#!")
  rescue ArgumentError, SystemCallError
    false
  end

  def ruby?(root, path)
    path.end_with?(".rb", ".rake") || File.open(File.join(root, path), &:gets).to_s.include?("ruby")
  end

  # The file's lines, scrubbed and chomped.
  def lines(root, path)
    File.readlines(File.join(root, path)).map { |l| l.scrub.chomp }
  rescue SystemCallError
    []
  end

  def comment?(line)
    line.lstrip.start_with?("#")
  end

  # True when +line+ starts `op` in a raw shape (not through the wrapper).
  def raw_line?(line, ruby:)
    return false if comment?(line) || line.match?(METERED)

    line.match?(LITERAL_ARGV) || line.match?(VAR_ARGV) ||
      (ruby ? line.match?(RUBY_STRING_FORM) || line.match?(RUBY_BACKTICK_FORM) : line.match?(SHELL_FORM))
  end

  # True when +line+ starts `op` through the metered wrapper.
  def metered_line?(line)
    !comment?(line) && line.match?(METERED)
  end

  # [path, lineno, line, window] for every raw (unmetered) `op` invocation. The
  # window is the two lines either side, for an allowance that must see the meter
  # beside an injected call.
  def raw_hits(root, paths = files(root))
    paths.flat_map do |path|
      ruby = ruby?(root, path)
      all = lines(root, path)
      all.each_with_index.map do |line, i|
        next unless raw_line?(line, ruby: ruby)

        [path, i + 1, line.strip, all[[i - 2, 0].max..(i + 2)].join("\n")]
      end.compact
    end
  end

  # The files that run `op` themselves, metered or raw, sorted.
  def direct_callers(root, paths = files(root))
    paths.select do |path|
      ruby = ruby?(root, path)
      lines(root, path).any? { |line| metered_line?(line) || raw_line?(line, ruby: ruby) }
    end
  end
end
