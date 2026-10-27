# frozen_string_literal: true

# [unit] SOURCE PIN: no Ruby under bin/ spawns `op` directly. Every 1Password
# call goes through OpMeter.popen (Ruby) or op_metered (shell), which bound each
# attempt and log it to .agents/op-reads.log. From 06:14 to 08:17 MDT on
# 2026-10-27 every `op` call hung; a bare IO.popen("op", ...) waits for as long
# as the 1Password daemon does, and the release tooling waited with it.
#
# A literal "op" as the first argument of IO.popen, an Open3 call, system, spawn
# or exec is the shape every one of the bare calls had (bin/r2-backup,
# bin/lib/dev_google_client.rb, bin/lib/domain_cutover.rb). The shell half has
# its own wrapper and its own tests (test/lib/op_meter_test.rb).
#
#   ruby -Itest test/lib/op_reads_are_bounded_test.rb

require "minitest/autorun"

class OpReadsAreBoundedTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BARE_OP = /(?:IO\.popen|Open3\.\w+|\bsystem|\bspawn|\bexec)\(\s*(?:\{[^}]*\}\s*,\s*|\w+\s*,\s*)?\[?\s*["']op["']/

  def ruby_sources
    Dir.glob(File.join(ROOT, "bin", "**", "*")).select do |path|
      next false unless File.file?(path)
      next true if path.end_with?(".rb")

      File.open(path) { |f| f.gets.to_s }.match?(/\A#!.*ruby/)
    end
  end

  def test_no_ruby_under_bin_spawns_op_outside_the_bounded_wrapper
    offenders = ruby_sources.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next if line.lstrip.start_with?("#")

        "#{path.delete_prefix("#{ROOT}/")}:#{i + 1}: #{line.strip}" if BARE_OP.match?(line)
      end
    end

    assert_empty offenders, "spawn op through OpMeter.popen (bin/lib/op_meter.rb), never bare:\n#{offenders.join("\n")}"
  end

  # The pin bites: the shapes the converted call sites had are matched.
  def test_the_pattern_matches_the_bare_shapes_it_replaced
    [
      %(value = IO.popen(["op", "read", ref], err: File::NULL, &:read)),
      %(IO.popen(env, ["op", "read", ref], err: File::NULL, &:read).to_s.strip),
      %(Open3.popen3("op", "read", item) do |stdin, stdout|),
      %(Open3.capture2e({ "OP_CACHE" => "false" }, "op", "whoami"))
    ].each { |line| assert_match BARE_OP, line }
    refute_match BARE_OP, %(OpMeter.popen({}, ["op", "read", ref], via: "x", err: File::NULL))
  end
end
