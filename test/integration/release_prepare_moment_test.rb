# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

# [integration] `bin/release prepare` prints the qa-release · prepare moment card
# AFTER prepare's own output, on every way out, and its exit status is prepare's.
#
# It runs bin/release.rb's REAL dispatcher in a bare Ruby child (no Rails, no
# bundler), with ARGV ["prepare"]. `prepare` itself is never run: the child stubs
# the method the moment bin/release.rb defines it (Object.method_added), so the
# stub answers like a QA-not-green prepare, or aborts. Nothing is promoted, merged
# or deployed. The dream bank is a throwaway directory (DREAM_BANK_DIR).
class ReleasePrepareMomentTest < ActiveSupport::TestCase
  RELEASE = Rails.root.join("bin/release.rb").to_s
  BARE_ENV = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze
  CHILD = <<~RUBY
    release = ARGV.shift
    class Object
      def self.method_added(name)
        return unless name == :prepare && !@stubbed

        @stubbed = true
        mode = ENV["STUB_PREPARE"]
        define_method(:prepare) do
          puts "STUB PREPARE OUTPUT"
          $stdout.flush
          mode == "abort" ? exit(1) : :qa_not_green
        end
        private :prepare
      end
    end
    $PROGRAM_NAME = release
    ARGV.replace(["prepare"])
    load release
  RUBY

  def run_prepare(bank, mode)
    Open3.capture2e(BARE_ENV.merge("DREAM_BANK_DIR" => bank, "STUB_PREPARE" => mode),
                    RbConfig.ruby, "-e", CHILD, RELEASE)
  end

  def with_bank
    Dir.mktmpdir("prepare-moment") do |bank|
      { "prepare" => "Red CI at prepare?", "ship" => "At ship?" }.each do |step, question|
        path = File.join(bank, "sops/qa-release/at-#{step}.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "---\nquestion: \"#{question}\"\nanswer: \"Rerun the whole run.\"\nwhy: \"Flaky.\"\n" \
                         "status: approved\nsop: qa-release\nstep: #{step}\n---\n")
      end
      yield bank
    end
  end

  test "[integration] a QA-not-green prepare prints its output, then the card, and keeps its exit status" do
    with_bank do |bank|
      out, status = run_prepare(bank, "green-stub")

      assert_equal 3, status.exitstatus, "prepare's own exit (QA not green) stands:\n#{out}"
      assert_includes out, "## Moment: qa-release · prepare"
      assert_includes out, "**Q: Red CI at prepare?** (`at-prepare`)"
      refute_includes out, "at-ship", "another step's dream waits for its own command"
      assert_operator out.index("STUB PREPARE OUTPUT"), :<, out.index("## Moment"), "the card comes after prepare's output"
    end
  end

  test "[integration] an aborted prepare still prints the card and exits with the abort's status" do
    with_bank do |bank|
      out, status = run_prepare(bank, "abort")

      assert_equal 1, status.exitstatus, out
      assert_includes out, "## Moment: qa-release · prepare"
    end
  end

  test "[integration] with no step dream to read, prepare prints no card and its exit is unchanged" do
    Dir.mktmpdir("empty-bank") do |bank|
      out, status = run_prepare(File.join(bank, "missing"), "green-stub")

      assert_equal 3, status.exitstatus, out
      assert_includes out, "STUB PREPARE OUTPUT", "control: the dispatcher ran prepare"
      refute_includes out, "## Moment"
    end
  end
end
