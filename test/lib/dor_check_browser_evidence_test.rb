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
  def with_client_repo(files, lane: true)
    Dir.mktmpdir do |dir|
      git = ->(a) { assert(system("git -C #{dir} #{a} >/dev/null 2>&1"), "git #{a}") }
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m base")
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

  def check_in(dir, devops, changed)
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      env = SessionEnv.neutralized.merge(
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_DIFF_ROOT" => dir,
        "DOR_CHECK_DIFF_BASE" => "base-ref",
        "DOR_CHECK_CHANGED_FILES" => changed
      )
      out = IO.popen(env, "#{BIN} --file #{path} 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
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
                   "Alpine directives were 157 of 268 detections across 406 measured units. " \
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
