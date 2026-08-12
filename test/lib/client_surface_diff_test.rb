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
      { "app/views/studio/banners/_stack.html.erb" => NAVBAR_JUMP }
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
      surfaces = ClientSurfaceDiff.added_programs([path], { path => AT_TIME_SCRIPT })
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

  # ==== VENDORED DEPENDENCY SOURCE IS NOT THIS APP'S BROWSER SURFACE ================
  #
  # THE VECTOR THIS SUITE DID NOT IMAGINE. The first cut of these tests killed 16 of
  # 16 mutations and was still wrong, because every fixture path was one WE would
  # write. CI supplied the one we would not: `vendor/` is not in .gitignore, so
  # `git ls-files --others` reports the whole vendored bundle as untracked, and a
  # vendored gem's rescues/*.html.erb is a real ERB template carrying a real
  # <script>. Three previously-green DorCheckTest cases went red (PR #801).
  #
  # The gate was proven correct on the inputs its author imagined. So the fixtures
  # now contain the input he did not — and this test is the reason the next person
  # cannot quietly re-anchor template? on extension alone.
  VENDORED = %w[
    vendor/bundle/ruby/3.3.0/gems/actionpack-8.1.3/lib/action_dispatch/middleware/templates/rescues/diagnostics.html.erb
    vendor/bundle/ruby/3.3.0/gems/actionpack-8.1.3/lib/action_dispatch/middleware/templates/rescues/_source.html.erb
    vendor/bundle/ruby/3.3.0/gems/actiontext-8.1.3/app/assets/javascripts/actiontext.js
    vendor/bundle/ruby/3.3.0/gems/actioncable-8.1.3/app/assets/javascripts/actioncable.js
    vendor/bundle/ruby/3.3.0/gems/railties-8.1.3/lib/rails/templates/rails/welcome/index.html.erb
    node_modules/@playwright/test/index.html
    .bundle/gems/foo-1.0/app/views/foo/_widget.html.erb
    tmp/cache/assets/sprite.js
  ].freeze

  # NOT vendored-and-excluded: importmap pins these and Propshaft serves them, so
  # they reach a browser exactly as app/javascript/ does. Two directories under one
  # `vendor/` parent with opposite answers — which is why the anchor is a ROOT list
  # rather than a judgment about the word "vendor".
  VENDOR_SERVED = %w[
    vendor/javascript/chart.js.js vendor/javascript/chartkick.esm.js
  ].freeze

  def test_unit_importmap_served_vendor_javascript_is_a_surface
    VENDOR_SERVED.each do |path|
      assert ClientSurfaceDiff.served?(path), "#{path} is pinned by importmap and served"
      assert_equal 1, ClientSurfaceDiff.added_programs([path], {}, {}).size,
                   "#{path} reaches a browser; missing it is a silent hole, and it sits one "                    "directory from vendor/bundle/ which must stay excluded"
    end
    assert_empty ClientSurfaceDiff.added_surfaces(
      ["vendor/bundle/ruby/3.3.0/gems/actiontext-8.1.3/app/assets/javascripts/actiontext.js"], {}, {}
    ), "vendor/bundle stays excluded by the same root rule that includes vendor/javascript"
  end

  def test_unit_vendored_dependency_source_is_never_a_surface
    VENDORED.each do |path|
      refute ClientSurfaceDiff.served?(path),
             "#{path} is dependency source, not a path THIS app serves"
      refute ClientSurfaceDiff.template?(path), path
      refute ClientSurfaceDiff.script_asset?(path), path
      assert_empty ClientSurfaceDiff.added_surfaces([path], { path => "<script>boom()</script>" }),
                   "#{path} fired the gate. CI vendors dependencies into the tree, so this turns a " \
                   "measured 2.8% blocking rate into 'any diff on a machine with a vendored bundle' " \
                   "— green locally, red in CI, which is the exact signature of the CHANGELOG " \
                   "basename bite this gate's own file already suffered."
      assert_empty ClientSurfaceDiff.added_programs([path], { path => "<script>boom()</script>" }), path
    end
  end

  # Coordinator check 2: the REPORT path must not over-fire either. Sixty vendored
  # suggestions is not a blocker, but it is noise that trains people to skip the
  # section — which costs the gate its only channel in a repo with no lane.
  def test_unit_vendored_paths_do_not_reach_the_report_path_either
    contents = VENDORED.to_h { |p| [p, "<script>boom()</script>"] }
    assert_empty ClientSurfaceDiff.present_surfaces(VENDORED, contents, {}),
                 "a report on sixty vendored files trains people to ignore the section"
  end

  # The anchor must not be so tight it stops seeing OUR templates. This is the
  # both-directions half: the fix is only correct if it still fires on real work.
  def test_unit_our_own_served_paths_are_still_surfaces
    {
      "app/views/studio/banners/_stack.html.erb" => :template,
      "app/views/layouts/application.html.erb" => :template,
      "app/components/chart_component.html.erb" => :template,
      "app/javascript/application.js" => :script,
      "app/assets/javascripts/studio/sortable.js" => :script,
      "public/widget.js" => :script
    }.each do |path, kind|
      assert ClientSurfaceDiff.served?(path), "#{path} IS served by this app"
      if kind == :template
        assert ClientSurfaceDiff.template?(path), path
        assert_equal 1, ClientSurfaceDiff.added_programs([path], { path => "<script>go()</script>" }).size,
                     "#{path}: the vendor fix must not stop the gate seeing OUR templates"
      else
        assert_equal 1, ClientSurfaceDiff.added_programs([path], {}).size, path
      end
    end
  end

  # ==== A TAG, NOT THE WORD =========================================================
  #
  # THE THIRD VECTOR NOBODY IMAGINED — after vendored paths and vendor/javascript/.
  # The detector matched the TEXT `<script` anywhere, so an ERB comment SAYING there
  # is no script demanded a Playwright spec. Every one of these is LIVE in the
  # ecosystem today, and the first is multi-line: the offending line carries no
  # `<%#` at all, because the comment opened two lines earlier. That is why the
  # classifier compares masked FILE VERSIONS and not hunk lines — no per-line or
  # per-hunk rule can see context that sits outside the hunk.
  TURF_GOAL_FEED = <<~ERB
    <%# A data-only node appended to the hidden goal feed on the live page. The
        page's MutationObserver reads these data-* attrs, fires a toast, then removes
        the node. NO <script> here — Turbo doesn't execute scripts inside broadcast
        <template>s. Locals: event ("goal"|"final"), team (Team|nil). %>
    <div data-event="<%= event %>"></div>
  ERB

  HUB_BOARD_COMMENT = <<~ERB
    <%# window.studioBoard — the Alpine factory behind the studio/board primitive.
        It MUST live at page level: a <script> inside the board component template
        would be cloned by Alpine and never run. %>
    <%= render "studio/board_assets" %>
  ERB

  HTML_COMMENT = <<~ERB
    <!-- do NOT put a <script> tag in here; the layout owns it -->
    <div class="card"></div>
  ERB

  def test_unit_the_word_script_inside_a_comment_is_not_a_program
    {
      "app/views/contests/_goal_feed_item.html.erb" => TURF_GOAL_FEED,
      "app/views/layouts/application.html.erb" => HUB_BOARD_COMMENT,
      "app/views/shared/_card.html.erb" => HTML_COMMENT
    }.each do |path, body|
      assert_empty ClientSurfaceDiff.added_programs([path], { path => body }, { path => "" }),
                   "#{path}: the WORD <script> inside a comment is not a script TAG. Blocking here " \
                   "means editing a comment that says there is no script demands a Playwright " \
                   "spec — prose comment blocks are this ecosystem's highest-churn edit shape, so " \
                   "it fires early, often, and trains people straight onto [browser-bypass]."
      assert_empty ClientSurfaceDiff.added_surfaces([path], { path => body }, { path => "" }), path
    end
  end

  # THE OPPOSITE MISTAKE, AND THE ONE THAT MATTERS MORE. Defect 3 was an ERB comment
  # that TERMINATED EARLY; the leaked prose carried a literal script tag that opened
  # a phantom element and swallowed the real script. A mask that trusted the OPENER
  # would hide exactly the defect this gate exists for. Masking non-greedily — the
  # way ERB itself closes at the first %> — leaks it back into view.
  def test_unit_a_comment_that_terminates_early_still_leaks_its_script
    path = "app/views/studio/_at_time_script.html.erb"
    # TWO `%>` are load-bearing. With only one, a greedy mask and an ERB-accurate
    # non-greedy mask behave identically and the test proves nothing — a mutation
    # run caught exactly that and this fixture is the repair. Greedy swallows from
    # the FIRST `<%#` to the LAST `%>`, hiding the script between them; ERB (and
    # this module) close at the first.
    leaky = <<~ERB
      <%# this comment ends early %> and then <script>window.__atTimeFmt = f;</script>
      <%# a second, entirely ordinary comment %>
      <div></div>
    ERB
    programs = ClientSurfaceDiff.added_programs([path], { path => leaky }, { path => "" })
    assert_equal 1, programs.size,
                 "a comment closing at the FIRST %> leaks the rest as live markup — that IS defect " \
                 "3. If the mask swallows it, the gate is blind to its own motivating case."
    refute_empty ClientSurfaceDiff.script_blocks(leaky),
                 "the leaked script must survive masking"
  end

  def test_unit_a_real_script_next_to_a_comment_still_fires
    path = "app/views/x.html.erb"
    body = "<%# no script here %>\n<script>go()</script>\n"
    assert_equal 1, ClientSurfaceDiff.added_programs([path], { path => body }, { path => "" }).size,
                 "masking the comment must not mask the tag beside it"
  end

  # ==== VERSION COMPARISON, NOT HUNK LINES ==========================================
  def test_unit_editing_a_comment_in_a_script_bearing_file_does_not_block
    path = "app/views/studio/_at_time_script.html.erb"
    base = "<%# old note %>\n<script>go()</script>\n"
    head = "<%# a completely rewritten note mentioning <script> %>\n<script>go()</script>\n"
    assert_empty ClientSurfaceDiff.added_programs([path], { path => head }, { path => base }),
                 "the script is UNCHANGED; only prose moved. Blocking a copy fix in a " \
                 "script-bearing partial is the over-refusal this design rejects."
  end

  # Rewriting an existing script's BODY: REPORTED, not blocked — and the boundary is
  # measured, not asserted. Blocking it took hub firing from 2.8% to 12.1% and the
  # whole 407-unit corpus from 9.3% to 20.6%, because roughly one hub PR in eight
  # legitimately edits an inline board/live-FX script — while catching none of the
  # three motivating defects, each of which introduced a NEW script.
  # Re-measure with `bin/measure-client-surface` before moving this line.
  def test_unit_rewriting_an_existing_script_body_reports_but_does_not_block
    path = "app/views/x.html.erb"
    base = "<script>\n  var a = 1;\n</script>\n"
    head = "<script>\n  var a = compute(window.tz);\n</script>\n"

    assert_empty ClientSurfaceDiff.added_programs([path], { path => head }, { path => base }),
                 "blocking every inline-script body edit is the blanket rule arriving one level " \
                 "down; measured at 4x the hub's firing rate for no motivating case"
    present = ClientSurfaceDiff.present_surfaces([path], { path => head }, { path => base })
    assert_equal 1, present.size, "but it must still be SAID — the script did change"
    assert present.first.program?
  end

  def test_unit_adding_a_second_script_to_an_existing_file_blocks
    path = "app/views/x.html.erb"
    base = "<script>go()</script>\n"
    head = "<script>go()</script>\n<script>alsoGo()</script>\n"
    assert_equal 1, ClientSurfaceDiff.added_programs([path], { path => head }, { path => base }).size,
                 "a NEW block in an existing file is an addition, not a rewrite"
  end

  def test_unit_an_unchanged_file_adds_nothing
    path = "app/views/x.html.erb"
    body = "<script>go()</script>\n"
    assert_empty ClientSurfaceDiff.added_programs([path], { path => body }, { path => body })
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
      all = ClientSurfaceDiff.added_surfaces([path], { path => line })
      assert_equal 1, all.size, "#{line} should be DETECTED"
      assert_equal reason, all.first.reason
      refute all.first.program?,
             "#{line.inspect} must not BLOCK. Alpine directives are 148 of 248 detections across " \
             "407 measured units (bin/measure-client-surface); blocking them makes the cheapest " \
             "shape the most expensive."
      assert_empty ClientSurfaceDiff.added_programs([path], { path => line })
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
  #
  # This pins the OUTCOME, not the mechanism. The module used to carry an explicit
  # TEST_ROOTS exclusion; once both predicates were anchored on SERVED_ROOTS a
  # mutation proved that exclusion unkillable — dead code — and it was removed. The
  # property survives it, which is the point: widen SERVED_ROOTS to reach a test
  # root and this test goes red, whatever the module calls the rule that day.
  def test_unit_test_roots_are_never_a_surface
    ["e2e/at_time_flag.spec.js", "e2e/helpers.js", "test/views/bar_stack_test.rb",
     "test/dummy/app/views/x.html.erb", "test/dummy/app/assets/javascripts/x.js",
     "tests/turf_vault.ts", "spec/views/x.html.erb"].each do |path|
      assert_empty ClientSurfaceDiff.added_surfaces([path], { path => "<script>x()</script>" }),
                   "#{path} is under a test root — it is evidence or a fixture, never a shipped surface"
    end
  end

  # The structural fact the removal of TEST_ROOTS rests on. If someone widens
  # SERVED_ROOTS to overlap a test root, the exclusion that used to be explicit is
  # gone and this says so directly, rather than leaving the test above to fail with
  # a puzzling message.
  def test_unit_served_roots_stay_disjoint_from_every_test_root
    %w[test/ tests/ e2e/ spec/].each do |root|
      assert ClientSurfaceDiff.disjoint_from_served?(root),
             "SERVED_ROOTS now overlaps #{root}. The explicit TEST_ROOTS exclusion was removed as " \
             "dead code precisely because these lists were disjoint; overlapping them re-opens " \
             "'adding a Playwright spec demands a Playwright spec' with nothing left to stop it."
    end
  end

  # ==== INERT <script> TYPES ========================================================
  def test_unit_non_executable_script_types_are_not_programs
    path = "app/views/x.html.erb"
    ['<script type="application/ld+json">', "<script type='text/template'>",
     '<script type="text/x-template">'].each do |line|
      assert_empty ClientSurfaceDiff.added_programs([path], { path => line }),
                   "#{line} is parsed as data; the browser runs nothing"
    end
  end

  def test_unit_an_executable_script_with_other_attributes_is_still_a_program
    path = "app/views/x.html.erb"
    ["<script>", '<script type="text/javascript">', '<script defer nonce="<%= nonce %>">',
     '<script type="module">'].each do |line|
      assert_equal 1, ClientSurfaceDiff.added_programs([path], { path => line }).size,
                   "#{line} executes"
    end
  end

  # ==== PRESENT vs ADDED ============================================================
  # Defect 3 was an ERB COMMENT edit that killed a script. The file-granularity read
  # catches it; it must REPORT rather than block, or every copy fix in a
  # script-bearing partial is refused.
  def test_unit_a_carried_script_is_present_but_not_added
    path = "app/views/studio/_at_time_script.html.erb"
    base = "<%# an old note %>\n" + AT_TIME_SCRIPT
    head = "<%# a note this diff rewrote %>\n" + AT_TIME_SCRIPT

    assert_empty ClientSurfaceDiff.added_programs([path], { path => head }, { path => base }),
                 "the diff added no script, so it must not BLOCK"
    present = ClientSurfaceDiff.present_surfaces([path], { path => head }, { path => base })
    assert_equal 1, present.size,
                 "the file still CARRIES a script — an ERB comment that terminates early can kill " \
                 "it, which is exactly defect 3"
    refute present.first.added?
  end

  def test_unit_present_does_not_double_report_an_added_surface
    path = "app/views/x.html.erb"
    assert_empty ClientSurfaceDiff.present_surfaces([path], { path => "<script>go()</script>" }, { path => "" }),
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
