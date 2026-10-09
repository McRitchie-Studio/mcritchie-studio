# frozen_string_literal: true

# Each release CLI test hands its subprocesses a temp directory of its own.
# Standalone: ruby -Itest test/lib/release_cli_subprocess_tmpdir_test.rb
#
# bin/release builds a gem at File.join(Dir.tmpdir, "release-<repo>-<version>.gem"),
# a path fixed per gem and version, and the ship tests' stubbed `gem build` copies a
# fixture there. The suite runs in forked workers, so two tests building
# studio-engine 0.96.0 at the same moment write one file between them, and the test
# that asserts a checksum REFUSAL reads the matching gem its control built.
require_relative "release_ship_final_gem_test"

class ReleaseCliSubprocessTmpdirTest < Minitest::Test
  # How long one side waits for the other before it gives up and says so.
  RENDEZVOUS_SECONDS = 60

  # Orders the two builds across the two subprocesses, around the stubbed `gem build`:
  # the side that builds FIRST marks its build and holds until the other has built;
  # the side that builds SECOND waits for that mark. So the second build always lands
  # between the first side's build and the first side's read of its artifact.
  def rendezvous(dir, first:)
    mine, theirs = first ? %w[first second] : %w[second first]
    <<~RUBY
      RENDEZVOUS = #{dir.inspect}
      def await_build(side)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + #{RENDEZVOUS_SECONDS}
        until File.exist?(File.join(RENDEZVOUS, side))
          return puts("RENDEZVOUS-TIMEOUT waiting for the " + side + " build") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.02
        end
      end
      self.singleton_class.prepend(Module.new do
        def sh(*a, **k)
          building = a[0] == "gem" && a[1] == "build"
          await_build(#{theirs.inspect}) if building && #{!first}
          super.tap do
            next unless building
            FileUtils.touch(File.join(RENDEZVOUS, #{mine.inspect}))
            await_build(#{theirs.inspect}) if #{first}
          end
        end
      end)
    RUBY
  end

  # Two workers, each one test of ReleaseShipFinalGemTest: test_ship_aborts_on_checksum_mismatch
  # and its control, test_a_final_that_matches_its_candidate_is_published_and_confirmed.
  def test_two_workers_running_the_mismatch_and_the_matching_case_at_once_each_read_their_own_built_gem
    mismatch = ReleaseShipFinalGemTest.new("the mismatch case")
    matching = ReleaseShipFinalGemTest.new("the matching case")

    Dir.mktmpdir("ship-gem-rendezvous") do |dir|
      worlds = { mismatch => "module Studio; LATE_EDIT = 1; end\n", matching => "module Studio; end\n" }.each_with_index.map do |(worker, body), index|
        cdn, built = %w[cdn built].map { |kind| File.join(dir, "#{kind}-#{index}").tap { |path| FileUtils.mkdir_p(path) } }
        worker.build_gem(cdn, "0.96.0.rc1")
        worker.ship_world(cdn: cdn, built: worker.build_gem(built, "0.96.0", body: body))
      end

      refused, shipped = [mismatch, matching].each_with_index.map do |worker, index|
        Thread.new do
          worker.run_cli(["--yes"], setup: worlds[index] + rendezvous(dir, first: index.zero?), call: worker.ship_gem_call("0.96.0.rc1"))
        end
      end.map(&:value)

      refute_includes refused + shipped, "RENDEZVOUS-TIMEOUT", "both builds ran, in order"
      assert_match(/REFUSED: ✗ studio-engine 0\.96\.0 built from fffffff does NOT match 0\.96\.0\.rc1, the candidate QA ran: lib\/studio\.rb differs/, refused,
                   "the mismatch case reads the gem IT built, whatever another worker built meanwhile")
      refute_includes refused, "PUSHED", "a final that is not the candidate's tree is never pushed: #{refused}"
      assert_includes shipped, "SHIPPED", shipped
      assert_includes shipped, "checksum: studio-engine 0.96.0 carries the same 2 file(s) and dependencies as 0.96.0.rc1"
    end
  ensure
    [mismatch, matching].compact.each(&:after_teardown)
  end

  def test_a_subprocess_sees_a_temp_directory_no_other_test_shares
    one = ReleaseShipFinalGemTest.new("one")
    other = ReleaseShipFinalGemTest.new("other")

    seen = [one, other].map { |worker| worker.eval_helper("Dir.tmpdir") }

    refute_equal seen.first, seen.last, "two tests, two directories"
    seen.each { |dir| refute_equal File.realpath(Dir.tmpdir), File.realpath(dir), "not the machine's shared temp directory" }
    assert_equal seen.first, one.eval_helper("Dir.tmpdir"), "one test's subprocesses share its directory across calls"
  ensure
    [one, other].compact.each(&:after_teardown)
  end

  def test_the_directory_is_removed_when_the_test_ends
    worker = ReleaseShipFinalGemTest.new("cleanup")
    dir = worker.eval_helper(%(File.write(File.join(Dir.tmpdir, "left-behind.gem"), "x").then { Dir.tmpdir }))
    assert File.exist?(File.join(dir, "left-behind.gem")), "the subprocess wrote into it"

    worker.after_teardown

    refute Dir.exist?(dir), "nothing a release subprocess leaves in its temp directory outlives the test"
  end
end
