# frozen_string_literal: true

# Standalone test for bin/dor-check's BROWSER-EVIDENCE gate. Run directly:
#   ruby -Itest test/lib/dor_check_browser_evidence_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# This is the GATE-level half of the proof. test/lib/client_surface_diff_test.rb
# proves the classifier answers correctly; this proves bin/dor-check ASKS it, reads
# the real git tree to do so, and ACTS on the answer. A green classifier wired to
# nothing is the failure mode worth more than either — a mutation harness caught
# exactly that on the test-only shape (a DEAD PATH: flipping the module's rule
# changed nothing, because nothing called it).
#
# It lives in its own file rather than in dor_check_test.rb (110 KB, shared by
# several concurrent agents) so a merge conflict cannot silently drop it.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "socket"
require_relative "../support/session_env"

class DorCheckBrowserEvidenceTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  SCRIPT_PARTIAL = <<~ERB
    <div data-studio-bar-stack>
      <span><%= bar.title %></span>
    </div>
    <script>
      var el = document.querySelector("[data-studio-bar-stack]");
      if (window.ResizeObserver) { new ResizeObserver(publish).observe(el); }
    </script>
  ERB

  ALPINE_PARTIAL = <<~ERB
    <div x-data="{ open: false }">
      <button @click="open = !open"><%= t(".toggle") %></button>
    </div>
  ERB

  SPEC = <<~JS
    test("the bar stack does not move the header", async ({ page }) => {
      await page.goto("/");
      const top = await page.evaluate(() => getComputedStyle(
        document.querySelector("header")).top);
      expect(top).toBe("0px");
    });
  JS

  # A complete, otherwise-passing ui-only contract, so the ONLY thing that can fail
  # a check below is the browser-evidence gate.
  def contract(extra_checks: [])
    {
      "shape" => "ui-only",
      "repositories" => ["mcritchie-studio"],
      "risk_tags" => ["ui"],
      "acceptance" => ["The bar stack reserves its own space"],
      "test_plan" => ["component"],
      "local_url" => "http://localhost:3033/style",
      "post_deploy_cmd" => "none",
      "checks_run" => ["[component] bin/rails test test/views/bar_stack_test.rb"] + extra_checks
    }
  end

  # A temp repo whose HEAD carries `files`, committed on top of an empty base, so
  # dor-check's REAL git path (client_added_lines) sees them as ADDED lines.
  # `lane:` controls whether the repo has a browser lane at all — the studio-engine
  # case is exactly `lane: false`.
  # `base:` seeds files into the BASE commit, before `base-ref` is cut — the only
  # way to exercise "this file already existed and the diff changed part of it",
  # which is the whole point of comparing versions rather than hunk lines.
  def with_client_repo(files, lane: true, base: {})
    Dir.mktmpdir do |dir|
      git = ->(a) { assert(system("git -C #{dir} #{a} >/dev/null 2>&1"), "git #{a}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m base")
      unless base.empty?
        base.each { |rel, body| write.call(rel, body) }
        git.call("add -A")
        git.call("commit -q -m baseline")
      end
      git.call("branch base-ref")

      if lane
        FileUtils.mkdir_p(File.join(dir, "e2e"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        File.write(File.join(dir, "config", "e2e_lane.yml"), "total_specs: 1\nquarantined: 0\nexecuted: 1\n")
      end

      files.each do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      git.call("add -A")
      git.call("commit -q -m feature")
      yield dir
    end
  end

  # WHERE THIS SUBPROCESS'S BOARD WRITES GO, AND WHY IT IS PINNED.
  #
  # bin/dor-check defaults BASE_URL to ENV.fetch("TASK_API_BASE",
  # "https://mcritchie.studio") — PRODUCTION — and a real merge-gate verdict shells
  # bin/gate to open+close a durable GateRun, which is a board write. This suite is
  # safe from that today only because every invocation passes --file, and the emit
  # is gated `options[:file].nil?`.
  #
  # THAT IS A GUARD INSIDE THE CODE UNDER TEST, which is the wrong place for this
  # suite's containment to live: delete that one condition in bin/dor-check and this
  # file starts writing GateRuns to the production board, silently, with every
  # assertion still green. The retro leak we closed had exactly that shape — a test
  # shelling a CLI whose write was invisible from the test's own assertions.
  #
  # So containment is pinned HERE, on the path, not inferred from the callee's
  # behaviour: TASK_API_BASE points at a local sink this test owns. Proven to
  # intercept rather than assumed — see
  # test_integration_the_board_pin_actually_intercepts, which drives the DANGEROUS
  # shape (no --file, so the emit DOES fire) and asserts the sink RECEIVED the
  # request. A positive receipt, not the absence of one.
  SINK_HOST = "127.0.0.1"

  def board_pinned_env(extra = {})
    SessionEnv.neutralized.merge(
      "TASK_API_BASE" => "http://#{SINK_HOST}:#{@sink_port || 9}",
      "ATOMIC_CAPTURE_URL" => "http://#{SINK_HOST}:#{@sink_port || 9}"
    ).merge(extra)
  end

  def check_in(dir, devops, changed)
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      env = board_pinned_env(
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_DIFF_ROOT" => dir,
        "DOR_CHECK_DIFF_BASE" => "base-ref",
        "DOR_CHECK_CHANGED_FILES" => changed
      )
      out = IO.popen(env, "#{BIN} --file #{path} 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  GATE_BIN = File.expand_path("../../bin/gate", __dir__)

  # A fake secret so the child gets FAR ENOUGH to make a board call.
  #
  # The first version of this self-test passed locally and failed in CI, and the
  # cause is worth recording because it is the same ambient-coupling family
  # SessionEnv exists for, running the other way. bin/dor-check resolves
  # AGENT_API_SECRET from ENV, then 1Password, then the repo's .env, and `die!`s if
  # all three miss. A dev worktree HAS a .env, so the child reached the auth POST
  # and the sink saw it. CI has none of the three — .env is gitignored,
  # AGENT_API_SECRET appears nowhere in ci.yml, and TaskBoard::OP is the hardcoded
  # macOS path /opt/homebrew/bin/op on an Ubuntu runner — so the child exited at
  # agent_secret BEFORE opening a socket. The sink saw nothing, and the receipt
  # correctly refused.
  #
  # So the fix is to stop depending on the machine having a real credential, NOT to
  # weaken the receipt. The value is fake and can only ever be offered to a
  # localhost sink, because TASK_API_BASE is pinned in the same env hash.
  PIN_PROOF_SECRET = "pin-proof-not-a-real-secret"

  # Run `cmd` with the board pinned at a sink this test owns; return the HTTP
  # request lines the sink received.
  def sink_requests(cmd)
    server = TCPServer.new(SINK_HOST, 0)
    port = server.addr[1]
    base = "http://#{SINK_HOST}:#{port}"
    received = []
    accepter = Thread.new do
      while (client = server.accept)
        received << client.gets.to_s
        client.write("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    env = SessionEnv.neutralized.merge(
      "TASK_API_BASE" => base, "ATOMIC_CAPTURE_URL" => base,
      "AGENT_API_SECRET" => PIN_PROOF_SECRET
    )
    IO.popen(env, "#{cmd} 2>/dev/null", &:read)

    deadline = Time.now + 20
    sleep 0.05 while received.empty? && Time.now < deadline
    received
  ensure
    accepter&.kill
    server&.close
  end

  # THE HARNESS SELF-TEST. A pin nobody proved is advice.
  #
  # Covers BOTH binaries that can write to the board, each driven directly, because
  # they are separate processes with separate env reads:
  #
  #   bin/dor-check — in the shape that DOES emit (a real slug, no --file).
  #   bin/gate      — the binary that actually writes the durable GateRun. Driving
  #                   it directly is deliberate: reaching it THROUGH dor-check would
  #                   need the sink to impersonate a whole board (auth token, task
  #                   JSON, a complete verdict), and a fake that elaborate fails for
  #                   its own reasons and stops testing the pin.
  #
  # If a future change routes either one's board calls somewhere this pin cannot
  # reach, this fails and NAMES the portability break, instead of the suite quietly
  # resuming writes to production.
  def test_integration_the_board_pin_actually_intercepts
    dor = sink_requests("#{BIN} some-slug-that-does-not-exist")
    refute_empty dor,
                 "the board pin did NOT intercept bin/dor-check: it made no request to the pinned " \
                 "TASK_API_BASE. Either it reached a DIFFERENT host — production is its default — " \
                 "or it died before opening a socket (that is what a missing AGENT_API_SECRET does; " \
                 "see PIN_PROOF_SECRET). Containment for this suite lives on this pin; if the pin " \
                 "is not on the path, the suite is one deleted `options[:file].nil?` away from " \
                 "writing GateRuns to the live board."
    assert_match(%r{^(GET|POST|PATCH|PUT) }, dor.first,
                 "expected an HTTP request line at the sink, got #{dor.first.inspect}")
  end

  def test_integration_the_gate_writer_is_pinned_too
    gate = sink_requests("#{GATE_BIN} open task some-slug-that-does-not-exist dor")
    refute_empty gate,
                 "bin/gate — the binary that WRITES the durable GateRun — reached no pinned host. " \
                 "dor-check spawns it fire-and-forget with the caller's env, so if it resolves a " \
                 "different base URL than TASK_API_BASE, pinning dor-check buys nothing and the " \
                 "GateRun lands on the live board."
    assert_match(%r{^(GET|POST|PATCH|PUT) }, gate.first,
                 "expected an HTTP request line at the sink, got #{gate.first.inspect}")
  end

  PARTIAL = "app/views/studio/banners/_stack.html.erb"

  # ==== THE BLOCKING CASE ===========================================================
  # This is defect 2 replayed at the gate: a diff that adds a script partial, in a
  # repo WITH a lane, carrying no e2e spec. The real submitted commit for
  # local-at-time-format was exactly this and dor-check PASSED it; the browser guard
  # only arrived after a human bounced it.
  def test_integration_an_added_script_with_no_browser_evidence_is_refused
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL }) do |dir|
      out, code = check_in(dir, contract, PARTIAL)

      refute_equal 0, code,
                   "a diff that adds an inline <script> shipped with no browser evidence. This is " \
                   "the local-at-time-format submit state, which passed every gate and was wrong in " \
                   "Chrome and Safari.\n#{out}"
      assert_match(/ADDS browser code and no browser ever saw it run/, out)
      assert_match(/#{Regexp.escape(PARTIAL)}/, out,
                   "the refusal must NAME the file, or the builder has to guess\n#{out}")
      assert_match(/inline <script>/, out, "and name WHAT it found\n#{out}")
    end
  end

  # The refusal must steer away from the assertion that caused defect 3.
  def test_integration_the_refusal_refuses_string_presence_as_evidence
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL }) do |dir|
      out, = check_in(dir, contract, PARTIAL)

      assert_match(/__atTimeFmt/, out,
                   "the guidance must cite the guard test that WAS the failure it guarded against")
      assert_match(/NOT that a token appears in the markup/, out,
                   "a builder told only 'add browser evidence' will write the string assertion again")
      assert_match(/computed style|page\.evaluate|post-interaction/, out,
                   "it must name what a live browser can produce that a String cannot\n#{out}")
    end
  end

  # ==== THE PASSING CASE ============================================================
  def test_integration_an_added_script_with_a_changed_spec_passes
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL, "e2e/bar_stack.spec.js" => SPEC }) do |dir|
      out, code = check_in(dir, contract, "#{PARTIAL}\ne2e/bar_stack.spec.js")

      assert_equal 0, code,
                   "a client diff that DID bring a browser spec must pass — a gate that refuses " \
                   "correct work teaches people to route around it\n#{out}"
      refute_match(/ADDS browser code/, out)
    end
  end

  def test_integration_a_wholly_quarantined_spec_does_not_satisfy_the_gate
    quarantined = %(test("bar stack @quarantine", async ({ page }) => {});)
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL, "e2e/bar_stack.spec.js" => quarantined }) do |dir|
      out, code = check_in(dir, contract, "#{PARTIAL}\ne2e/bar_stack.spec.js")

      refute_equal 0, code,
                   "a quarantined spec is excluded from the lane's executed set BY CONTRACT. " \
                   "Crediting it would let a builder satisfy the gate with a spec the lane is " \
                   "contracted never to run — the self-declaration disease the e2e lane exists " \
                   "to cure.\n#{out}"
    end
  end

  # ==== A COMMENT SAYING "NO SCRIPT" MUST NOT DEMAND A PLAYWRIGHT SPEC =============
  #
  # The defect that sent PR #801 back as rework, replayed END TO END at the gate
  # rather than at the classifier — because the classifier being right is not the
  # claim; the claim is that `bin/dor-check` exits 0. This exact text is live at
  # turf-monster/app/views/contests/_goal_feed_item.html.erb:3, and turf HAS an e2e
  # lane, so before the fix editing this comment demanded a browser spec.
  #
  # Note it is MULTI-LINE: the line carrying the word `<script>` has no `<%#` on it
  # at all. Any per-line or per-hunk rule is blind here by construction.
  GOAL_FEED_COMMENT = <<~ERB
    <%# A data-only node appended to the hidden goal feed on the live page. The
        page's MutationObserver reads these data-* attrs, fires a toast, then removes
        the node. NO <script> here — Turbo doesn't execute scripts inside broadcast
        <template>s. Locals: event ("goal"|"final"), team (Team|nil). %>
    <div data-event="<%= event %>" data-team="<%= team&.name %>"></div>
  ERB

  def test_integration_a_comment_saying_there_is_no_script_does_not_block
    path = "app/views/contests/_goal_feed_item.html.erb"
    with_client_repo({ path => GOAL_FEED_COMMENT }) do |dir|
      out, code = check_in(dir, contract, path)

      assert_equal 0, code,
                   "editing a comment that SAYS there is no script demanded a Playwright spec. " \
                   "Prose comment blocks are this ecosystem's highest-churn edit shape, so this " \
                   "fires early and often and trains people straight onto [browser-bypass] — the " \
                   "credibility loss the whole design exists to avoid. It also fails acceptance " \
                   "criterion 2 verbatim: the gate refuses only what it can honestly judge.\n#{out}"
      refute_match(/ADDS browser code/, out, out)
      refute_match(/browser evidence/i, out, "not even a suggestion — there is no surface here\n#{out}")
    end
  end

  # The same file, one comment word changed, with a REAL script alongside it. The
  # script is untouched, so the diff still must not block.
  def test_integration_editing_prose_beside_an_untouched_script_does_not_block
    path = "app/views/studio/_at_time_script.html.erb"
    base = "<%# an old note %>\n<script>window.__atTimeFmt = f;</script>\n"
    head = "<%# a rewritten note that mentions <script> tags %>\n<script>window.__atTimeFmt = f;</script>\n"
    with_client_repo({ path => head }, base: { path => base }) do |dir|
      out, code = check_in(dir, contract, path)

      assert_equal 0, code, "the script is byte-identical; only prose moved\n#{out}"
      refute_match(/ADDS browser code/, out, out)
    end
  end

  # ==== THE MUTATION PROOF: A SERVER-ONLY DIFF IS NOT MOLESTED ======================
  # If ANY of these blocks, the gate has become the blanket browser requirement, and
  # the cheapest change in the repo just became the most expensive.
  SERVER_ONLY = {
    "app/models/task.rb" => "class Task < ApplicationRecord; end\n",
    "app/controllers/tasks_controller.rb" => "class TasksController < ApplicationController; end\n",
    "lib/cert_evidence.rb" => "module CertEvidence; end\n",
    "db/migrate/20260811_add_thing.rb" => "class AddThing < ActiveRecord::Migration[7.1]; end\n",
    "config/routes.rb" => "Rails.application.routes.draw {}\n",
    "app/views/tasks/show.html.erb" => "<h1><%= @task.title %></h1>\n<p><%= @task.body %></p>\n"
  }.freeze

  def test_integration_a_server_only_diff_is_never_touched_by_this_gate
    SERVER_ONLY.each do |path, body|
      with_client_repo({ path => body }) do |dir|
        out, code = check_in(dir, contract, path)

        assert_equal 0, code,
                     "#{path} triggered the browser-evidence gate. Nothing in it reaches a browser, " \
                     "so this is a false refusal — the failure that makes people route around the " \
                     "gate, which is worse than the gap it closes.\n#{out}"
        refute_match(/ADDS browser code/, out, "#{path}: no browser finding at all\n#{out}")
        refute_match(/browser evidence/i, out, "#{path}: not even a suggestion\n#{out}")
      end
    end
  end

  def test_integration_a_whole_server_only_diff_is_silent
    with_client_repo(SERVER_ONLY.to_h) do |dir|
      out, code = check_in(dir, contract, SERVER_ONLY.keys.join("\n"))
      assert_equal 0, code, out
      refute_match(/browser/i, out)
    end
  end

  # ==== BINDINGS REPORT, THEY DO NOT BLOCK ==========================================
  def test_integration_an_alpine_binding_reports_but_does_not_block
    path = "app/views/components/_dropdown.html.erb"
    with_client_repo({ path => ALPINE_PARTIAL }) do |dir|
      out, code = check_in(dir, contract, path)

      assert_equal 0, code,
                   "Alpine directives are 148 of 248 detections across 407 measured units " \
                   "(bin/measure-client-surface). " \
                   "Blocking them IS the blanket rule.\n#{out}"
      assert_match(/suggestion/, out, "but it must still be SAID — silence teaches nothing\n#{out}")
      assert_match(/client binding/, out, out)
    end
  end

  # ==== NO LANE => REPORT, NOT REFUSE ===============================================
  # studio-engine has no e2e/ and its CI runs no browser. Two of the three defects
  # that motivated this gate were there. Blocking would be a refusal with no remedy.
  def test_integration_a_repo_with_no_browser_lane_reports_instead_of_blocking
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL }, lane: false) do |dir|
      out, code = check_in(dir, contract, PARTIAL)

      assert_equal 0, code,
                   "this repo has NO browser lane, so there is no evidence to demand. Refusing " \
                   "here would block correct work with no action the builder could take.\n#{out}"
      assert_match(/BROWSER-EVIDENCE HOLE/, out,
                   "the hole must be NAMED and loud, not silent — a silent hole is how two of the " \
                   "three motivating defects shipped\n#{out}")
      assert_match(/NO BROWSER LANE/, out, out)
    end
  end

  # ==== THE ESCAPE HATCH IS A RECORD ================================================
  def test_integration_a_recorded_bypass_is_honored_and_flagged
    devops = contract(extra_checks: ["[browser-bypass] this script only runs in the print stylesheet path"])
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL }) do |dir|
      out, code = check_in(dir, devops, PARTIAL)

      assert_equal 0, code, "a recorded bypass is honored — a gate with no hatch gets routed " \
                            "around silently\n#{out}"
      assert_match(/BROWSER-EVIDENCE GATE BYPASSED/, out,
                   "and it must be LOUD, so it is routed around on purpose, in front of a " \
                   "reviewer\n#{out}")
      assert_match(/print stylesheet path/, out, "the recorded reason must be echoed\n#{out}")
    end
  end

  # ==== THE BUILD GATE IS EXEMPT ====================================================
  def test_integration_the_build_gate_does_not_ask_for_browser_evidence
    with_client_repo({ PARTIAL => SCRIPT_PARTIAL }) do |dir|
      Dir.mktmpdir do |tmp|
        path = File.join(tmp, "task.json")
        File.write(path, JSON.generate(
          "slug" => "t", "title" => "T", "metadata" => { "devops" => contract }
        ))
        env = SessionEnv.neutralized.merge(
          "DOR_CHECK_SUITE_EVIDENCE" => "ok", "DOR_CHECK_DIFF_ROOT" => dir,
          "DOR_CHECK_DIFF_BASE" => "base-ref", "DOR_CHECK_CHANGED_FILES" => PARTIAL
        )
        out = IO.popen(env, "#{BIN} --file #{path} --gate build 2>/dev/null", &:read)
        assert_equal 0, $?.exitstatus,
                     "browser evidence is a BUILD ARTIFACT, unknowable at design time — the same " \
                     "reason local_url and the tiers are not asked for at the build gate\n#{out}"
      end
    end
  end
end
