# frozen_string_literal: true

# [unit] No live file names a retired route or a deleted file. robots.txt,
# test/timings.yml, the fast-cert comments and the test file names once named
# paths and files that no longer exist; this keeps them from coming back.
#
# test/integration/retired_routes_test.rb is the one file allowed to name the
# retired paths: it lists them on purpose, to prove each one answers 404.
#
#   ruby -Itest test/lib/retired_names_sweep_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

class RetiredNamesSweepTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  SCANNED_DIRS = %w[public config test bin e2e .github].freeze

  RETIRED_NAMES = [
    # Routes that answer 404.
    "/alex/heartbeat", "/alex/insights", "/alex/pipeline", "/xan/heartbeat/spans",
    # Deleted files.
    "bin/docker-entrypoint", "ci_test_command_test", "system_test_browser_test",
    "builder_policy_test",
    # Test files renamed after the routes they test.
    "atomic_actions_controller_test", "atomic_events_controller_test",
    "event_grades_controller_test", "heartbeat_all_spans_test",
    "heartbeat_event_grade_test"
  ].freeze

  ALLOWED = [
    "test/integration/retired_routes_test.rb",
    "test/lib/retired_names_sweep_test.rb"
  ].freeze

  def scanned_files
    SCANNED_DIRS.flat_map { |dir| Dir.glob(File.join(ROOT, dir, "**", "*"), File::FNM_DOTMATCH) }
                .select { |path| File.file?(path) }
                .map { |path| path.delete_prefix("#{ROOT}/") }
                .reject { |rel| rel.include?("/tmp/") || rel.start_with?("test/fixtures/files/") }
  end

  def hits_in(rel)
    text = File.read(File.join(ROOT, rel), encoding: "UTF-8")
    return [] unless text.valid_encoding?

    RETIRED_NAMES.select { |name| text.include?(name) }
  end

  def test_unit_no_scanned_file_names_a_retired_route_or_deleted_file
    offenders = (scanned_files - ALLOWED).filter_map do |rel|
      hits = hits_in(rel)
      "#{rel}: #{hits.join(', ')}" if hits.any?
    end
    assert_empty offenders, "retired names are still referenced:\n  #{offenders.join("\n  ")}"
  end

  # Keeps the sweep honest: it must actually read the files it claims to, and
  # the matcher must find a retired name where one is known to live.
  def test_unit_the_sweep_reads_the_files_it_guards
    files = scanned_files
    %w[public/robots.txt test/timings.yml bin/lib/fast_cert.rb].each do |rel|
      assert_includes files, rel, "the sweep must scan #{rel}"
    end
    refute_empty hits_in("test/integration/retired_routes_test.rb"),
                 "the matcher must find the retired paths the 404 registry lists"
  end

  def test_unit_renamed_test_files_exist_under_their_route_names
    %w[
      test/controllers/api/v1/agent_actions_controller_test.rb
      test/controllers/api/v1/agent_activities_controller_test.rb
      test/controllers/api/v1/activity_grades_controller_test.rb
      test/integration/heartbeat_all_activities_test.rb
      test/integration/heartbeat_activity_grade_test.rb
    ].each { |rel| assert File.exist?(File.join(ROOT, rel)), "#{rel} must exist" }
  end
end
