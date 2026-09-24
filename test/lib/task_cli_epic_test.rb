# frozen_string_literal: true

# `bin/task --epic` — the CLI writer for `tasks.epic_slug`, the handle the board
# card's epic chip prints and `/tasks?epic=<slug>` filters on.
#
# THE PROPERTY: the value rides the wire as a TOP-LEVEL column beside "devops",
# never inside it (metadata.devops.epic_slug is the shadow store
# Task::DEVOPS_COLUMN_KEYS refuses); `--epic none` reaches the wire as JSON null
# rather than being dropped as falsy; an absent flag never mentions the column;
# a non-slug dies at the flag; and the read-backs (`show`, `field`, `list
# --epic`) resolve the COLUMN.
#
# Its own file with its own SMALL stub board: test/lib/task_cli_test.rb sits at
# its hotspot ceiling, and these cases need only a server that records requests
# and echoes a record — not that file's 261-line harness. (The ceiling registry's
# path is deliberately not spelled here — the fast-cert mapper follows a spelled
# config path, and this file would otherwise join that config's mapped set; see
# test/lib/fast_cert_subject_test.rb.)
#
#   ruby -Itest test/lib/task_cli_epic_test.rb

require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCliEpicTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SOURCE = File.read(BIN)

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  # Drive the real binary against a one-shot stub board. Returns
  # [requests, out, err, status]. `record` is the task the stub serves on every
  # GET / PATCH / POST; the index serves `index_rows`.
  def run_task(args, record: {}, index_rows: [])
    @sandbox ||= Dir.mktmpdir("task-epic-sandbox")
    served = { "slug" => "demo-task", "stage" => "building", "title" => "Demo Task",
               "merged" => nil, "release_slug" => nil, "dependencies" => [], "epic_slug" => nil,
               "metadata" => { "devops" => { "kind" => "feature" } } }.merge(record)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    thread = Thread.new { serve(server, requests, served, index_rows) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{port}",
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, out, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, record, index_rows)
    loop do
      client = server.accept
      request_line = client.gets or break
      method, path = request_line.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip if value
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }
      payload =
        if path == "/api/v1/auth"
          JSON.generate("token" => "stub-token")
        elsif method == "GET" && path =~ %r{\A/api/v1/tasks(\?.*)?\z}
          JSON.generate("data" => index_rows)
        else
          JSON.generate("data" => record)
        end
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    # server closed — stop serving
  end

  def patch_body(requests)
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch, "expected a PATCH for the update"
    JSON.parse(patch[:body])
  end

  # --- the write: a column beside devops, never inside it -----------------------

  def test_update_epic_writes_the_top_level_column_not_a_devops_shadow
    requests, _out, err, status = run_task(%w[update demo-task --epic devops-v3])
    assert status.success?, err
    parsed = patch_body(requests)

    assert_equal "devops-v3", parsed["epic_slug"]
    refute parsed.key?("devops"), "an --epic-only update touches no devops key at all"
  end

  def test_epic_is_lowercased_at_the_flag
    requests, = run_task(%w[update demo-task --epic DevOps-V3])
    assert_equal "devops-v3", patch_body(requests)["epic_slug"],
                 "the CLI and the model agree on the canonical form before the board sees it"
  end

  def test_create_carries_epic_beside_devops
    requests, _out, err, status = run_task(["create", "--title", "Epic Create Task", "--kind", "feature",
                                            "--epic", "devops-v3"])
    assert status.success?, err
    post = requests.find { |r| r[:method] == "POST" && r[:path] == "/api/v1/tasks" }
    refute_nil post, "expected a POST create"
    parsed = JSON.parse(post[:body])

    assert_equal "devops-v3", parsed["epic_slug"]
    assert_equal "feature", parsed.dig("devops", "kind")
    assert_nil parsed.dig("devops", "epic_slug"), "a column written under devops is the shadow store nothing reads"
  end

  # The CLEAR must reach the wire as null. `nil` is falsy, so a truth-tested body
  # builder would drop it and hand the operator a 200 for a clear that never happened.
  def test_epic_none_sends_an_explicit_null
    requests, _out, err, status = run_task(%w[update demo-task --epic none])
    assert status.success?, err
    parsed = patch_body(requests)

    assert parsed.key?("epic_slug"), "the clear must be IN the body, not omitted as falsy"
    assert_nil parsed["epic_slug"]
  end

  def test_an_update_without_the_flag_never_mentions_epic_slug
    requests, = run_task(%w[update demo-task --branch feat/x])
    refute patch_body(requests).key?("epic_slug"),
           "omission must mean UNCHANGED — sending null here would clear every task it touched"
  end

  def test_a_non_slug_epic_dies_at_the_flag_before_any_write
    requests, _out, err, status = run_task(["update", "demo-task", "--epic", "DevOps V3!"])
    refute status.success?
    assert_match(/--epic .* is not a slug/, err)
    assert_empty requests.select { |r| r[:method] == "PATCH" }, "nothing reaches the board"
  end

  # --- begin: a create flag, refused (with the remedy) on a resume --------------

  def test_begin_resume_refuses_epic_and_names_the_update_remedy
    _requests, _out, err, status = run_task(%w[begin demo-task --epic devops-v3])
    refute status.success?
    assert_match(/--epic/, err)
    assert_match(/update \S+ --epic/, err, "the refusal must say where the value DOES belong")
  end

  # --- the read-backs resolve the column ----------------------------------------

  def test_show_prints_the_epic_line_only_when_set
    _requests, out_set, = run_task(%w[show demo-task], record: { "epic_slug" => "devops-v3" })
    assert_match(/^  epic: devops-v3$/, out_set)

    _requests, out_unset, = run_task(%w[show demo-task])
    refute_match(/epic:/, out_unset, "a task with no epic prints nothing for it in the terse view")
  end

  def test_show_verbose_renders_the_column_in_three_states
    _requests, set, = run_task(%w[show demo-task --verbose], record: { "epic_slug" => "devops-v3" })
    assert_match(/epic_slug: devops-v3/, set)

    _requests, unset, = run_task(%w[show demo-task --verbose])
    assert_match(/epic_slug: no epic/, unset)

    _requests, out, = run_task(%w[show demo-task --verbose],
                               record: { "epic_slug" => "devops-v3", "metadata" => { "devops" => { "kind" => "feature", "epic_slug" => "shadow" } } })
    assert_match(/epic_slug: devops-v3/, out, "the column wins over a stale devops shadow")
  end

  def test_field_reads_epic_slug_from_the_column_never_the_devops_shadow
    _requests, out, _err, status = run_task(
      %w[field demo-task epic_slug],
      record: { "epic_slug" => "from-column", "metadata" => { "devops" => { "epic_slug" => "from-devops" } } }
    )
    assert status.success?
    assert_equal "from-column", out.strip
  end

  def test_list_epic_filters_through_the_index_param
    requests, out, _err, status = run_task(%w[list --epic DevOps-V3],
                                           index_rows: [{ "slug" => "member", "stage" => "building", "title" => "Member" }])
    assert status.success?
    index = requests.find { |r| r[:method] == "GET" && r[:path].start_with?("/api/v1/tasks?") }
    refute_nil index, "list must query the index"
    assert_includes index[:path], "epic=devops-v3"
    assert_match(/member/, out)
  end

  def test_list_epic_none_is_refused_rather_than_listing_everything
    requests, _out, err, status = run_task(%w[list --epic none])
    refute status.success?
    assert_match(/needs an epic slug/, err)
    assert_empty requests.select { |r| r[:method] == "GET" && r[:path].start_with?("/api/v1/tasks") }
  end

  # --- the family guard, extended to the fourth flag family ---------------------

  # test/lib/task_cli_test.rb's test_top_level_flag_families_never_share_a_column
  # pins TOP_FLAGS exactly, which is why `--epic` is its own family; this extends
  # the same collision property across that family.
  def test_the_epic_family_shares_no_column_with_the_other_top_level_families
    literal = ->(name) { SOURCE[/^#{name} = (\{[^\n]*\}|%w\[[^\]]*\])\.freeze$/m, 1] }
    scalar_keys = literal.call("TOP_SCALAR_FLAGS").to_s.scan(/=>\s*"([^"]+)"/).flatten
    list_keys = literal.call("TOP_LIST_FLAGS").to_s.scan(/=>\s*"([^"]+)"/).flatten
    size_keys = literal.call("SIZE_FLAGS").to_s.scan(/=>\s*"([^"]+)"/).flatten
    top_keys = literal.call("TOP_FLAGS").to_s.scan(/--([a-z-]+)/).flatten

    assert_equal %w[epic_slug], scalar_keys, "extraction sanity — TOP_SCALAR_FLAGS reached real content"
    all = scalar_keys + list_keys + size_keys + top_keys
    assert_equal all.uniq, all, "two top-level flag families write the same column"
    assert_match(/TOP_SCALAR_FLAGS\.keys/, SOURCE, "the family must be in PARSE_FLAG_NAMES or the unknown-flag refusal swallows it")
    assert_match(/TOP_SCALAR_FLAGS\.each_value \{ \|col\| body\[col\] = top\[col\] if top\.key\?\(col\) \}/, SOURCE,
                 "the value must reach the body by key? — a truth test drops the clear")
  end
end
