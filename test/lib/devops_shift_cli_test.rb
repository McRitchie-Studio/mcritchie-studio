# frozen_string_literal: true

# [unit] tests for bin/devops-shift — the shift-lease CLI. The board behavior is
# covered by test/controllers/api/v1/devops_shifts_controller_test.rb; here we pin
# the CLI's own logic: exit-code branching on the acquire verdict, the held-shift
# marker, and the graceful no-session/no-lane fallbacks — with a fake API so no
# server is needed.
#
#   ruby -Itest test/lib/devops_shift_cli_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"

load File.expand_path("../../bin/devops-shift", __dir__)

class DevopsShiftCliTest < Minitest::Test
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

  Resp = Struct.new(:code, :body)

  # A stand-in for AgentApi that records POSTs and returns canned JSON. `data` is
  # the {data: …} payload every endpoint wraps its result in.
  class FakeApi
    attr_reader :posts

    def initialize(projects_dir:, data: {})
      @projects_dir = projects_dir
      @data = data
      @posts = []
    end

    def token = "tok"
    def projects_dir = @projects_dir
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(method, path, body = nil, **)
      @posts << { method: method, path: path, body: body }
      Resp.new(200, JSON.generate({ data: @data }))
    end
  end

  def cli(env: {}, data: {}, projects_dir:)
    c = DevopsShiftCli.new(env: { "DEVOPS_SHIFT_SESSION" => SESSION }.merge(env),
                           out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, FakeApi.new(projects_dir: projects_dir, data: data))
    c
  end

  def marker(projects_dir)
    File.join(projects_dir, ".agents", "sessions", "#{SESSION}.devops-shift")
  end

  def test_acquire_success_exits_zero_and_writes_the_marker
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj, data: { "acquired" => true, "holder" => { "label" => "Exeggcute" } })
             .run(%w[acquire avi])
      assert_equal DevopsShiftCli::OK, code
      assert_match(/shift acquired/, @out.string)
      assert_equal "avi\n", File.read(marker(proj)), "the held-shift marker is written for the statusline renewer"
    end
  end

  def test_acquire_when_held_exits_stood_down_and_names_the_holder
    Dir.mktmpdir do |proj|
      code = cli(projects_dir: proj,
                 data: { "acquired" => false, "disposition" => "held_by_other",
                         "holder" => { "label" => "Exeggcute", "session" => "sess-A", "heartbeat_age" => 3 } })
             .run(%w[acquire avi])
      assert_equal DevopsShiftCli::STOOD_DOWN, code, "a held lane makes the second launch stand down (exit 10)"
      assert_match(/STAND DOWN/, @out.string)
      assert_match(/Exeggcute/, @out.string, "the step-down names the live holder")
      refute File.exist?(marker(proj)), "a stood-down session must NOT write a held-shift marker"
    end
  end

  def test_acquire_without_a_session_id_fails_open_not_wedged
    Dir.mktmpdir do |proj|
      code = cli(env: { "DEVOPS_SHIFT_SESSION" => "" }, projects_dir: proj).run(%w[acquire avi])
      assert_equal DevopsShiftCli::CANT_RUN, code, "no session id → fail open (exit 1), never a false hold"
    end
  end

  def test_acquire_without_a_lane_is_a_usage_error
    Dir.mktmpdir do |proj|
      assert_equal DevopsShiftCli::CANT_RUN, cli(projects_dir: proj).run(%w[acquire])
      assert_match(/needs a lane/, @err.string)
    end
  end

  def test_release_clears_the_marker_and_posts_release
    Dir.mktmpdir do |proj|
      FileUtils.mkdir_p(File.dirname(marker(proj)))
      File.write(marker(proj), "avi\n")
      c = cli(projects_dir: proj, data: { "released" => true })
      assert_equal DevopsShiftCli::OK, c.run(%w[release avi])
      refute File.exist?(marker(proj)), "release clears the held-shift marker"
      assert(c.instance_variable_get(:@api).posts.any? { |p| p[:path] == "/api/v1/devops_shifts/release" })
    end
  end

  def test_renew_is_always_a_clean_exit_zero
    Dir.mktmpdir do |proj|
      assert_equal DevopsShiftCli::OK, cli(projects_dir: proj, data: { "renewed" => true }).run(%w[renew avi])
    end
  end

  def test_parse_flags_reads_label_value
    Dir.mktmpdir do |proj|
      flags = cli(projects_dir: proj).parse_flags(%w[--label Exeggcute])
      assert_equal "Exeggcute", flags["label"]
    end
  end
end
