# frozen_string_literal: true

# Standalone test for bin/lib/client_surface_diff.rb. Run directly:
#   ruby -Itest test/lib/client_surface_diff_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# The classifier half of the browser-evidence gate. The gate-level half — proving
# bin/dor-check ASKS this module and acts on the answer — is in
# test/lib/dor_check_test.rb. A green classifier wired to nothing is the failure
# mode worth more than either, which is why both exist.

require "minitest/autorun"
require_relative "../../bin/lib/client_surface_diff"

class ClientSurfaceDiffTest < Minitest::Test
  # ==== THE THREE MOTIVATING DEFECTS, AS THE DETECTOR SEES THEM =====================
  # Not paraphrases: the actual construct each introducing diff added. A gate that
  # misses its own motivating case is worth knowing about before it ships, so each
  # one is asserted by name.

  NAVBAR_JUMP = <<~ERB
    <div data-studio-bar-stack>
    <script>
      var el = document.querySelector("[data-studio-bar-stack]");
      if (h > 0) document.documentElement.style.setProperty("--studio-bars-h", h + "px");
      if (window.ResizeObserver) { window.__studioBarObserver = new ResizeObserver(publish); }
    </script>
  ERB

  AT_TIME_SCRIPT = <<~ERB
    <script>
      function isUS(zone) { return US_ZONES.has(zone); }
      window.__atTimeFmt = fmt;
    </script>
  ERB

  def test_unit_defect_one_navbar_resize_observer_is_a_program
    surfaces = ClientSurfaceDiff.added_programs(
      ["app/views/studio/banners/_stack.html.erb"],
      { "app/views/studio/banners/_stack.html.erb" => NAVBAR_JUMP.lines }
    )
    assert_equal 1, surfaces.size,
                 "defect 1's introducing diff added a ResizeObserver that republished " \
                 "--studio-bars-h. If the detector cannot see it, the gate misses the case it " \
                 "was built for."
    assert_equal "an inline <script>", surfaces.first.reason
  end

  def test_unit_defect_two_and_three_at_time_script_partial_is_a_program
    ["app/views/shared/_at_time_script.html.erb",
     "app/views/studio/_at_time_script.html.erb"].each do |path|
      surfaces = ClientSurfaceDiff.added_programs([path], { path => AT_TIME_SCRIPT.lines })
      assert_equal 1, surfaces.size, "#{path} is 200+ lines of browser program"
      assert surfaces.first.program?
    end
  end

  # ==== THE MUTATION PROOF: A SERVER-ONLY DIFF IS NOT MOLESTED ======================
  # The whole design rests on the trigger being TARGETED. If any of these fires, the
  # gate has become the blanket browser requirement it exists to reject, and people
  # will route around it — which is worse than the gap, because a shape nobody
  # claims teaches nothing.
  SERVER_ONLY = {
    "app/models/task.rb" => "a model",
    "app/controllers/tasks_controller.rb" => "a controller",
    "app/jobs/sync_job.rb" => "a background job",
    "app/services/reviewer_selector.rb" => "a service",
    "db/migrate/20260811_add_thing.rb" => "a migration",
    "lib/cert_evidence.rb" => "a lib",
    "bin/dor-check" => "the gate itself",
    "config/routes.rb" => "routes",
    "Gemfile" => "the gem graph",
    ".github/workflows/ci.yml" => "CI config",
    "docs/agents/index.md" => "prose",
    "app/assets/stylesheets/application.css" => "a stylesheet",
    "config/importmap.rb" => "an importmap (ruby, not served JS)",
    "playwright.config.js" => "the e2e runner config (node, not a browser)",
    "bin/e2e-executed-set-check" => "a node-adjacent CLI"
  }.freeze

  def test_unit_server_only_paths_produce_no_surface_at_all
    SERVER_ONLY.each do |path, why|
      assert_empty ClientSurfaceDiff.added_surfaces([path], {}),
                   "#{path} (#{why}) triggered the browser-evidence gate. Nothing here reaches a " \
                   "browser, so demanding a Playwright spec for it is a false refusal — the exact " \
                   "failure that teaches people to route around the gate."
      assert_empty ClientSurfaceDiff.added_programs([path], {}), path
    end
  end

  def test_unit_a_whole_server_only_diff_is_silent
    assert_empty ClientSurfaceDiff.added_surfaces(SERVER_ONLY.keys, {})
  end

  # An ERB template with NO client construct must stay silent. This is the case that
  # separates "no browser evidence" from "no browser surface": a view changed, and
  # the detector can point at nothing in it.
  def test_unit_a_template_with_no_client_construct_is_silent
    path = "app/views/tasks/show.html.erb"
    lines = ["<h1><%= @task.title %></h1>", "<p class=\"text-sm\"><%= @task.body %></p>",
             "<%= link_to 'Back', tasks_path %>"]
    assert_empty ClientSurfaceDiff.added_surfaces([path], { path => lines }),
                 "a plain ERB view is not a browser surface; firing here is the blanket rule"
  end

  # ==== THE PROGRAM / BINDING SPLIT =================================================
  def test_unit_declarative_bindings_report_but_do_not_block
    {
      "<div x-data=\"{ open: false }\">" => "an Alpine directive",
      "<div x-show=\"open\">" => "an Alpine directive",
      "<button @click=\"open = !open\">" => "an Alpine event shorthand",
      "<div data-controller=\"dropdown\">" => "a Stimulus controller binding",
      "<a onclick=\"go()\">" => "an inline DOM event handler"
    }.each do |line, reason|
      path = "app/views/x.html.erb"
      all = ClientSurfaceDiff.added_surfaces([path], { path => [line] })
      assert_equal 1, all.size, "#{line} should be DETECTED"
      assert_equal reason, all.first.reason
      refute all.first.program?,
             "#{line.inspect} must not BLOCK. Alpine directives were 157 of 268 detections across " \
             "406 measured units; blocking them makes the cheapest shape the most expensive."
      assert_empty ClientSurfaceDiff.added_programs([path], { path => [line] })
    end
  end

  def test_unit_a_file_adding_both_reports_as_the_program
    path = "app/views/x.html.erb"
    lines = ["<div x-data=\"{}\">", "<script>doThing()</script>"]
    surfaces = ClientSurfaceDiff.added_surfaces([path], { path => lines })
    assert_equal 1, surfaces.size, "one surface per file, strongest tier"
    assert surfaces.first.program?,
           "a partial that adds an Alpine attribute AND a <script> is a program — reporting the " \
           "binding would downgrade a blocking case to a suggestion"
  end

  # ==== SERVED ROOTS: THE LOCATION RULE, BOTH DIRECTIONS ============================
  def test_unit_js_under_a_served_root_is_a_program
    ["app/javascript/application.js", "app/assets/javascripts/studio/sortable.js",
     "app/views/pwa/service-worker.js", "public/widget.js",
     "app/components/chart.ts"].each do |path|
      programs = ClientSurfaceDiff.added_programs([path], {})
      assert_equal 1, programs.size, "#{path} is served to a browser by construction"
      assert_equal "a browser-served script", programs.first.reason
    end
  end

  def test_unit_js_outside_a_served_root_is_not_a_surface
    ["playwright.config.js", "bin/tool.js", "config/webpack.js",
     "vendor/thing.js", "Rakefile.js"].each do |path|
      assert_empty ClientSurfaceDiff.added_surfaces([path], {}),
                   "#{path} runs in node or nowhere. A bare-extension rule would fire here, which " \
                   "is why SERVED_ROOTS exists."
    end
  end

  # A spec is the EVIDENCE. Counting it as a surface would make adding a Playwright
  # spec trigger the demand for a Playwright spec.
  def test_unit_test_roots_are_never_a_surface
    ["e2e/at_time_flag.spec.js", "e2e/helpers.js", "test/views/bar_stack_test.rb",
     "test/dummy/app/views/x.html.erb", "tests/turf_vault.ts"].each do |path|
      assert_empty ClientSurfaceDiff.added_surfaces([path], { path => ["<script>x()</script>"] }),
                   "#{path} is under a test root — it is evidence or a fixture, never a shipped surface"
    end
  end

  # ==== INERT <script> TYPES ========================================================
  def test_unit_non_executable_script_types_are_not_programs
    path = "app/views/x.html.erb"
    ['<script type="application/ld+json">', "<script type='text/template'>",
     '<script type="text/x-template">'].each do |line|
      assert_empty ClientSurfaceDiff.added_programs([path], { path => [line] }),
                   "#{line} is parsed as data; the browser runs nothing"
    end
  end

  def test_unit_an_executable_script_with_other_attributes_is_still_a_program
    path = "app/views/x.html.erb"
    ["<script>", '<script type="text/javascript">', '<script defer nonce="<%= nonce %>">',
     '<script type="module">'].each do |line|
      assert_equal 1, ClientSurfaceDiff.added_programs([path], { path => [line] }).size,
                   "#{line} executes"
    end
  end

  # ==== PRESENT vs ADDED ============================================================
  # Defect 3 was an ERB COMMENT edit that killed a script. The file-granularity read
  # catches it; it must REPORT rather than block, or every copy fix in a
  # script-bearing partial is refused.
  def test_unit_a_carried_script_is_present_but_not_added
    path = "app/views/studio/_at_time_script.html.erb"
    contents = { path => AT_TIME_SCRIPT }
    added = { path => ["<%# a comment that is all this diff changed %>"] }

    assert_empty ClientSurfaceDiff.added_programs([path], added),
                 "the diff added no script, so it must not BLOCK"
    present = ClientSurfaceDiff.present_surfaces([path], contents, added)
    assert_equal 1, present.size,
                 "the file still CARRIES a script — an ERB comment that terminates early can kill " \
                 "it, which is exactly defect 3"
    refute present.first.added?
  end

  def test_unit_present_does_not_double_report_an_added_surface
    path = "app/views/x.html.erb"
    added = { path => ["<script>go()</script>"] }
    assert_empty ClientSurfaceDiff.present_surfaces([path], { path => "<script>go()</script>" }, added),
                 "a surface the diff ADDED is reported by added_surfaces; reporting it twice would " \
                 "print a blocking finding and a suggestion for one line"
  end

  def test_unit_unreadable_content_is_not_guessed_at
    assert_empty ClientSurfaceDiff.present_surfaces(["app/views/x.html.erb"], {}, {}),
                 "a path with no content fetched is UNCLASSIFIED, not assumed clean and not assumed dirty"
  end

  # ==== EVIDENCE ====================================================================
  def test_unit_a_changed_e2e_spec_is_evidence
    assert_equal ["e2e/at_time_flag.spec.js"],
                 ClientSurfaceDiff.evidence_specs(["app/views/x.html.erb", "e2e/at_time_flag.spec.js"])
  end

  # THE CENTRAL REFUSAL. Defect 3's guard test was `assert_includes html, "__atTimeFmt"`
  # and it PASSED on a page whose script threw, because the token survived inside the
  # swallowed text. A Rails test observes a String. It is not browser evidence here.
  def test_unit_a_rails_test_is_never_browser_evidence
    ["test/integration/style_page_test.rb", "test/views/bar_stack_test.rb",
     "test/helpers/at_time_helper_test.rb", "test/system/navbar_test.rb"].each do |path|
      assert_empty ClientSurfaceDiff.evidence_specs([path]),
                   "#{path} renders to a String. Accepting it would re-admit the exact assertion " \
                   "that went green over a dead script."
    end
  end

  def test_unit_a_wholly_quarantined_spec_is_not_evidence
    path = "e2e/thing.spec.js"
    quarantined = %(test("does a thing @quarantine", async ({ page }) => {});)
    assert_empty ClientSurfaceDiff.evidence_specs([path], { path => quarantined }),
                 "a quarantined spec is excluded from the lane's executed set BY CONTRACT, so " \
                 "crediting it accepts evidence the lane is contracted not to run"
  end

  def test_unit_a_spec_with_one_live_test_is_evidence
    path = "e2e/thing.spec.js"
    mixed = <<~JS
      test("rotted one @quarantine", async ({ page }) => {});
      test("a live one", async ({ page }) => {});
    JS
    assert_equal [path], ClientSurfaceDiff.evidence_specs([path], { path => mixed })
  end

  def test_unit_an_unreadable_spec_is_credited_not_refused
    path = "e2e/thing.spec.js"
    assert_equal [path], ClientSurfaceDiff.evidence_specs([path], {}),
                 "the spec CHANGED; the runtime executed-set gate grades whether it ran. Refusing " \
                 "on a read failure would block correct work for an infrastructure fact."
  end

  # ==== LANE PRESENCE ===============================================================
  def test_unit_lane_presence_is_detected_from_the_repo
    assert ClientSurfaceDiff.lane_present?(File.expand_path("../..", __dir__)),
           "the hub HAS e2e/ + config/e2e_lane.yml"
    refute ClientSurfaceDiff.lane_present?("/nonexistent-repo-xyz"),
           "a repo with no e2e/ has no lane — the gate must REPORT there, not refuse with no remedy"
  end

  # ==== FAIL DIRECTION ==============================================================
  def test_unit_an_empty_observation_adds_nothing
    assert_empty ClientSurfaceDiff.added_surfaces([], {})
    assert_empty ClientSurfaceDiff.added_programs([], {})
    assert_empty ClientSurfaceDiff.evidence_specs([])
  end

  # A template path with NO added lines fetched cannot be shown to have added a
  # program. It must not block — the report path off the path list still fires.
  def test_unit_a_template_with_no_hunks_read_does_not_block
    assert_empty ClientSurfaceDiff.added_programs(["app/views/x.html.erb"], {}),
                 "an unreadable hunk is not proof of new browser code; blocking here would refuse " \
                 "correct work for a checkout that could not show us its diff"
  end
end
