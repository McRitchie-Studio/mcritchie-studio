# frozen_string_literal: true

# [unit] hub-security-gates-pass: bin/brakeman, the command CI's static lane runs
# (.github/workflows/reusable-ci.yml, `bin/brakeman --no-pager`), exits non-zero
# on any warning that config/brakeman.ignore does not excuse, and the ignore
# file excuses nothing without a reason.
#
# Each case scans a throwaway Rails app built in a tmpdir, so no deliberate
# warning ever sits in this repository. The clean app is the control: it shows
# the gate is not simply always red.

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"

class BrakemanGateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WRAPPER = File.join(ROOT, "bin", "brakeman")
  IGNORE_FILE = File.join(ROOT, "config", "brakeman.ignore")

  CLEAN_CONTROLLER = <<~RUBY
    class ProbeController < ApplicationController
      def show
        @rows = Probe.where(name: params[:name])
      end
    end
  RUBY

  # The deliberate finding: request input interpolated into SQL.
  WARNING_CONTROLLER = <<~RUBY
    class ProbeController < ApplicationController
      def show
        @rows = Probe.where("name = '\#{params[:name]}'")
      end
    end
  RUBY

  def build_app(dir, controller)
    FileUtils.mkdir_p(File.join(dir, "app", "controllers"))
    FileUtils.mkdir_p(File.join(dir, "config"))
    File.write(File.join(dir, "app", "controllers", "application_controller.rb"), <<~RUBY)
      class ApplicationController < ActionController::Base
        protect_from_forgery with: :exception
      end
    RUBY
    File.write(File.join(dir, "app", "controllers", "probe_controller.rb"), controller)
    File.write(File.join(dir, "config", "routes.rb"), %(Rails.application.routes.draw { get "probe", to: "probe#show" }\n))
    dir
  end

  # Runs the wrapper exactly as CI does, against `app`. Returns [exit status, report].
  def scan(app, *extra)
    out, status = Open3.capture2e(WRAPPER, "--no-pager", "-q", *extra, app, chdir: ROOT)
    [status.exitstatus, out]
  end

  def fingerprints(app)
    _status, out = scan(app, "-f", "json", "--no-exit-on-warn")
    JSON.parse(out[out.index("{")..])["warnings"].map { |w| w["fingerprint"] }
  end

  def write_ignore(app, entries)
    File.write(File.join(app, "config", "brakeman.ignore"),
               JSON.pretty_generate("ignored_warnings" => entries, "brakeman_version" => "test"))
  end

  def test_a_clean_app_passes_the_gate
    Dir.mktmpdir do |dir|
      status, out = scan(build_app(dir, CLEAN_CONTROLLER))
      assert_equal 0, status, "the control app should scan clean:\n#{out}"
    end
  end

  def test_one_new_warning_fails_the_gate
    Dir.mktmpdir do |dir|
      status, out = scan(build_app(dir, WARNING_CONTROLLER))
      refute_equal 0, status, "bin/brakeman exited 0 on an unignored SQL injection:\n#{out}"
      assert_match(/SQL Injection/, out)
    end
  end

  def test_an_ignored_warning_with_a_note_passes
    Dir.mktmpdir do |dir|
      app = build_app(dir, WARNING_CONTROLLER)
      write_ignore(app, fingerprints(app).map { |f| { "fingerprint" => f, "note" => "Test: reviewed and safe." } })
      status, out = scan(app)
      assert_equal 0, status, "an ignore entry with a note should excuse its warning:\n#{out}"
    end
  end

  def test_an_ignored_warning_without_a_note_fails
    Dir.mktmpdir do |dir|
      app = build_app(dir, WARNING_CONTROLLER)
      write_ignore(app, fingerprints(app).map { |f| { "fingerprint" => f, "note" => "" } })
      status, out = scan(app)
      refute_equal 0, status, "an ignore entry with no note excused its warning:\n#{out}"
    end
  end

  def test_an_obsolete_ignore_entry_fails
    Dir.mktmpdir do |dir|
      app = build_app(dir, CLEAN_CONTROLLER)
      write_ignore(app, [ { "fingerprint" => "0" * 64, "note" => "Excuses code that no longer exists." } ])
      status, out = scan(app)
      refute_equal 0, status, "an ignore entry for a warning that no longer exists passed:\n#{out}"
    end
  end

  # The hub's own ignore file: every entry names its fingerprint once and says
  # why it is a false positive.
  def test_every_hub_ignore_entry_carries_its_reason
    entries = JSON.parse(File.read(IGNORE_FILE)).fetch("ignored_warnings")
    refute_empty entries

    entries.each do |entry|
      where = "#{entry['file']}:#{entry['line']} (#{entry['fingerprint']})"
      assert_match(/\A\h{64}\z/, entry["fingerprint"].to_s, "#{where}: not a Brakeman fingerprint")
      note = entry["note"].to_s.strip
      assert_operator note.length, :>=, 40, "#{where}: the note must say why this is a false positive"
    end
    dupes = entries.map { |e| e["fingerprint"] }.tally.select { |_, n| n > 1 }.keys
    assert_empty dupes, "fingerprints listed more than once"
  end
end
