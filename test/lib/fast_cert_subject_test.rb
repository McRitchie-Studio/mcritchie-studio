# frozen_string_literal: true

# [unit] + [integration] tests for the SUBJECT REFERENCE in bin/lib/fast_cert.rb, the precision
# half of the fast cert's selection. Sibling fast_cert_family_test.rb pins the family hop for a
# tool that HAS a twin; this file pins what happens when it does not. A basename as an English
# word over-matches (config/environments/test.rb -> "Test"); the token is the subject's
# IDENTITY: a path for a file, the full constant for a class, plus the harness family for a tool
# with no same-named twin. BOTH DIRECTIONS ARE PINNED: wide sources must NARROW, and a source
# that already mapped correctly must be UNTOUCHED (see the restraint section).
# History: task grep-maps-three-hundred-tests.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_cert"

class FastCertSubjectTest < Minitest::Test
  REPO_ROOT = File.expand_path("../..", __dir__)
  SELF = "test/lib/fast_cert_subject_test.rb"

  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      yield dir
    end
  end

  # --- rung 2: the harness family reaches a tool whose TWIN WAS NEVER WRITTEN ----

  # The bin/task case, in miniature. There is no test/lib/task_test.rb in the hub
  # and there never was, so the family hop (gated on the twin EXISTING) never ran
  # and the grep asked for the word "task". The fixture reproduces exactly that
  # shape: no twin, three named siblings, and a bystander that merely says the word.
  def test_missing_twin_still_reaches_its_harness_family
    with_tree(
      "bin/task" => "#!/usr/bin/env ruby\n",
      "test/lib/task_cli_test.rb" => "class A; end\n",
      "test/lib/task_begin_test.rb" => "class B; end\n",
      "test/models/task_test.rb" => "# a task model test, mentions task everywhere\n"
    ) do |dir|
      mapped = FastCert.select_tests(dir, ["bin/task"])

      assert_equal %w[test/lib/task_begin_test.rb test/lib/task_cli_test.rb], mapped
      refute_includes mapped, "test/models/task_test.rb",
                      "the Task MODEL's test is not evidence about bin/task; it was 1 of 325 " \
                      "files the bare-word grep claimed"
    end
  end

  # The family for a missing twin is subject to the SAME ownership guard as the
  # family for a present one: a sibling that is somebody else's twin belongs to them.
  def test_missing_twin_family_still_rejects_a_sibling_owned_elsewhere
    with_tree(
      "bin/task" => "#!/usr/bin/env ruby\n",
      "bin/lib/task_author_fields.rb" => "module TaskAuthorFields; end\n",
      "test/lib/task_author_fields_test.rb" => "class A; end\n",
      "test/lib/task_cli_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/lib/task_cli_test.rb"], FastCert.select_tests(dir, ["bin/task"])
    end
  end

  # A DELETED test file has no existing twin either, and must not drag its whole
  # family in behind it. Same exclusion #family_tests makes, for the same reason.
  def test_a_changed_test_file_never_pulls_an_orphan_family
    with_tree(
      "test/lib/task_cli_test.rb" => "class B; end\n",
      "test/lib/task_begin_test.rb" => "class C; end\n"
    ) do |dir|
      # task_test.rb itself is absent from the tree (deleted in this diff).
      assert_empty FastCert.orphan_family(dir, "test/lib/task_test.rb")
    end
  end

  # --- test/commands/ is the SECOND harness namespace ---------------------------

  def test_bin_script_reaches_its_test_commands_twin_and_family
    with_tree(
      "bin/session-kickoff" => "#!/usr/bin/env ruby\n",
      "test/commands/session_kickoff_test.rb" => "SCRIPT = File.join(ROOT, 'bin', 'x')\n",
      "test/commands/session_kickoff_flags_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal %w[
        test/commands/session_kickoff_flags_test.rb
        test/commands/session_kickoff_test.rb
      ], FastCert.select_tests(dir, ["bin/session-kickoff"])
    end
  end

  # The ownership guard has to work in the commands namespace too, or a sibling
  # named after another script gets claimed by whoever prefixes it.
  def test_test_commands_family_rejects_another_scripts_twin
    with_tree(
      "bin/task" => "#!/usr/bin/env ruby\n",
      "bin/task-archive" => "#!/usr/bin/env ruby\n",
      "test/commands/task_archive_test.rb" => "class A; end\n",
      "test/commands/task_claim_gate_test.rb" => "class B; end\n"
    ) do |dir|
      assert_equal ["test/commands/task_claim_gate_test.rb"],
                   FastCert.select_tests(dir, ["bin/task"])
    end
  end

  # ...and a LIBRARY must not be read as the owner of a commands file. lib/ and
  # bin/lib/ convention-map into test/lib/ ONLY, so bin/lib/code_diff.rb cannot be
  # the owner of test/commands/code_diff_test.rb — rejecting on it would drop a
  # genuine sibling that nobody owns.
  def test_a_library_does_not_own_a_test_commands_file
    with_tree(
      "bin/qa" => "#!/usr/bin/env ruby\n",
      "bin/lib/qa_intake.rb" => "module QaIntake; end\n",
      "test/commands/qa_intake_test.rb" => "class A; end\n"
    ) do |dir|
      assert_equal ["test/commands/qa_intake_test.rb"], FastCert.select_tests(dir, ["bin/qa"])
    end
  end

  # bin/release.rb asked for test/lib/release.rb_test.rb — a path no convention in
  # this repo can produce, so it could never exist, so the file always fell to a
  # grep on the literal "release.rb" (51 files, 2026-09-07).
  def test_a_bin_ruby_file_drops_the_extension_before_asking_for_its_twin
    assert_equal %w[test/lib/release_test.rb test/commands/release_test.rb],
                 FastCert.convention_candidates("bin/release.rb")
  end

  # --- rung 3: the grep's SUBJECT REFERENCE -------------------------------------

  # A class is named by its FULL constant. app/services/news/review.rb defines
  # News::Review; "Review" is not a shorter spelling of it, it is a different token
  # the class is never referred to by — which is why all 39 of its matches were
  # coincidence.
  def test_a_nested_class_is_named_by_its_qualified_constant
    assert_equal ["News::Review"], FastCert.grep_tokens(REPO_ROOT, "app/services/news/review.rb")
    assert_equal ["Api::V1::TasksController"],
                 FastCert.grep_tokens(REPO_ROOT, "app/controllers/api/v1/tasks_controller.rb")

    with_tree(
      "app/services/news/review.rb" => "class News\n class Review; end\nend\n",
      "test/models/content_review_test.rb" => "# exercises Review of content\n",
      "test/services/news_review_flow_test.rb" => "News::Review.new(news).call\n"
    ) do |dir|
      mapped = FastCert.select_tests(dir, ["app/services/news/review.rb"])

      assert_equal ["test/services/news_review_flow_test.rb"], mapped
      refute_includes mapped, "test/models/content_review_test.rb",
                      "a test that says the word Review is not a test about News::Review"
    end
  end

  # Rails autoloads app/*/concerns as a root of its own, so the segment is not part
  # of the constant. Keeping it would name a constant that does not exist.
  def test_the_concerns_segment_is_not_part_of_the_constant
    assert_equal ["PositionConcern"],
                 FastCert.grep_tokens(REPO_ROOT, "app/models/concerns/position_concern.rb")
    assert_equal ["Api::Paginatable"],
                 FastCert.grep_tokens(REPO_ROOT, "app/controllers/concerns/api/paginatable.rb")
  end

  # A single-segment app file is unchanged — the fix adds a namespace, it does not
  # rename anything that already had none.
  def test_a_top_level_app_class_keeps_its_plain_constant
    assert_equal ["GateRun"], FastCert.grep_tokens(REPO_ROOT, "app/models/gate_run.rb")
    assert_equal ["TreeFingerprint"], FastCert.grep_tokens(REPO_ROOT, "bin/lib/tree_fingerprint.rb")
  end

  # A config file is named by its PATH and by the QUOTED BASENAME the path is SPLIT into. The bare
  # basename as a word made config/environments/test.rb hunt for "Test"; a path alone cannot see
  # `File.join(ROOT, "config", "rails_lane.yml")`. THE EXTENSION IS WHAT MAKES THE SECOND SPELLING
  # SAFE: "rails_lane.yml" is never an English word, unlike the bin side, whose quoted form has no
  # extension and still lets `"rake"` match `require "rake"`.
  # History: task config-sources-lose-their-tests.
  def test_a_config_file_is_named_by_its_path_or_its_quoted_basename
    assert_equal ["config/queue.yml", %("queue.yml")],
                 FastCert.grep_tokens(REPO_ROOT, "config/queue.yml")

    with_tree(
      "config/queue.yml" => "production:\n",
      "test/jobs/queue_priority_test.rb" => "# asserts the queue name ordering\n",
      "test/lib/queue_config_test.rb" => "YAML.load_file('config/queue.yml')\n",
      "test/lib/queue_contract_test.rb" => %(  PATH = File.join(ROOT, "config", "queue.yml")\n)
    ) do |dir|
      mapped = FastCert.select_tests(dir, ["config/queue.yml"])

      assert_equal %w[test/lib/queue_config_test.rb test/lib/queue_contract_test.rb], mapped
      refute_includes mapped, "test/jobs/queue_priority_test.rb",
                      "the word queue in prose is English, not a naming act"
    end
  end

  # THE QUALIFICATION: an initializer configures a class rather than defining one, so its
  # camelized basename is only a NAME when this repo owns that constant. Unqualified, this clause
  # hands config/environments/test.rb the token "Test" and config/initializers/studio.rb "Studio".
  # BOTH SIDES ARE PINNED IN ONE PLACE on purpose: a test proving only the gain goes green on a
  # mutation that drops the owner check.
  # History: task config-sources-lose-their-tests.
  def test_an_initializer_is_named_by_the_constant_it_wires_only_when_that_class_lives_here
    # The fixture deliberately uses names this REPO does not have. Writing the real
    # `EdgeGuard` here would make this file match config/initializers/edge_guard.rb in
    # the live tree below — a test polluting the mapping it measures.
    with_tree(
      "config/initializers/port_guard.rb" => "Rails.application.config.middleware.insert_before 0, PortGuard\n",
      "lib/middleware/port_guard.rb" => "class PortGuard; end\n",
      "config/initializers/beacon.rb" => "Beacon.configure { }\n",
      "test/lib/port_guard_test.rb" => "PortGuard.new(app, secret: s)\n",
      "test/lib/beacon_flow_test.rb" => "Beacon.signal(:up)\n"
    ) do |dir|
      assert_equal ["config/initializers/port_guard.rb", %("port_guard.rb"), "PortGuard"],
                   FastCert.grep_tokens(dir, "config/initializers/port_guard.rb"),
                   "lib/middleware/port_guard.rb owns PortGuard, so the initializer borrows it"
      assert_equal ["test/lib/port_guard_test.rb"],
                   FastCert.select_tests(dir, ["config/initializers/port_guard.rb"])

      assert_equal ["config/initializers/beacon.rb", %("beacon.rb")],
                   FastCert.grep_tokens(dir, "config/initializers/beacon.rb"),
                   "nothing in this tree defines Beacon, so it is a word, not a name"
      refute_includes FastCert.select_tests(dir, ["config/initializers/beacon.rb"]),
                      "test/lib/beacon_flow_test.rb"
    end
  end

  # A YAML FILE BORROWS NOTHING, even when a class of the same name is sitting right
  # there. config/port_guard.yml is a file; PortGuard is a class; a config that
  # happens to share a name with one is not that class's test subject.
  #
  # THIS CASE EXISTS BECAUSE THE GUARD WAS ONCE INERT. With the stem cut as
  # `File.basename(path, ".rb")`, a YAML path asked for "port_guard.yml.rb", matched
  # nothing, and produced [] with OR without the .rb guard — so deleting the guard
  # broke no test. Cutting the stem with File.extname makes this fixture decide it.
  def test_a_yaml_config_never_borrows_a_same_named_classs_constant
    with_tree(
      "config/port_guard.yml" => "enabled: true\n",
      "lib/middleware/port_guard.rb" => "class PortGuard; end\n",
      "test/lib/port_guard_test.rb" => "PortGuard.new(app)\n"
    ) do |dir|
      assert_equal ["config/port_guard.yml", %("port_guard.yml")],
                   FastCert.grep_tokens(dir, "config/port_guard.yml"),
                   "a YAML file defines no constant, so it may not borrow PortGuard"
      assert_empty FastCert.select_tests(dir, ["config/port_guard.yml"])
    end
  end

  # A SAME-NAMED SOURCE IS NOT AUTOMATICALLY THE OWNER. app/services/broadcasts/assets.rb and
  # app/services/content/assets.rb share a basename with config/initializers/assets.rb but define
  # `Broadcasts::Assets` and `Content::Assets`, not `Assets`. Qualifying on the basename would
  # hand the asset initializer the token `Assets`. THIS IS WHY THE CHECK ASKS #grep_tokens rather
  # than asking whether a file exists.
  # History: task config-sources-lose-their-tests.
  def test_a_same_named_source_owns_the_constant_only_if_it_is_named_by_it
    twin = "app/services/content/assets.rb"

    assert File.file?(File.join(REPO_ROOT, twin)),
           "#{twin} is the same-named source that must NOT qualify"
    assert_equal ["Content::Assets"], FastCert.grep_tokens(REPO_ROOT, twin),
                 "it is named Content::Assets, not Assets"

    assert_equal ["config/initializers/assets.rb", %("assets.rb")],
                 FastCert.grep_tokens(REPO_ROOT, "config/initializers/assets.rb"),
                 "no source in this repo is NAMED `Assets`, so the initializer borrows nothing"
  end

  # The two config .rb files whose unqualified constant WAS the defect, pinned
  # against the live repo so the guard cannot be satisfied by a friendly fixture.
  def test_no_english_constant_is_readmitted_for_this_repos_configs
    assert_equal ["config/environments/test.rb", %("test.rb")],
                 FastCert.grep_tokens(REPO_ROOT, "config/environments/test.rb")
    assert_equal ["config/initializers/studio.rb", %("studio.rb")],
                 FastCert.grep_tokens(REPO_ROOT, "config/initializers/studio.rb")
  end

  # A SCRIPT is named two ways, and both are deliberate: by path in code that RUNS
  # it, and as a bare quoted command name in the registries that ENUMERATE bin/.
  # Dropping the quoted spelling cost five scripts their only mapped test.
  def test_a_bin_script_is_named_by_path_or_by_quoted_command_name
    assert_equal ["bin/register-satellite", '"register-satellite"'],
                 FastCert.grep_tokens(REPO_ROOT, "bin/register-satellite")

    with_tree(
      "bin/register-satellite" => "#!/usr/bin/env ruby\n",
      "test/lib/bin_help_flag_class_test.rb" => %(  "register-satellite" => :optparse\n),
      "test/lib/runner_test.rb" => "system('bin/register-satellite', '--help')\n",
      "test/lib/prose_test.rb" => "# you can register-satellite by hand if you must\n"
    ) do |dir|
      mapped = FastCert.select_tests(dir, ["bin/register-satellite"])

      assert_equal %w[test/lib/bin_help_flag_class_test.rb test/lib/runner_test.rb], mapped
      refute_includes mapped, "test/lib/prose_test.rb",
                      "an unquoted mention in prose is English, not a naming act"
    end
  end

  # THE BOUNDARY RULE, pinned on its own because it cannot be one rule. An
  # unconditional \b kills the quoted spelling (\b before a quote demands a word
  # character before the quote, which a registry line never has) AND it fails open on
  # paths: /\bbin\/task\b/ MATCHES "bin/task-archive", because the hyphen is exactly
  # the non-word character \b wants. This test found that live.
  def test_a_quoted_token_takes_no_word_boundary
    assert_match FastCert.token_regexp('"register-satellite"'),
                 %(  "register-satellite" => :optparse)
  end

  def test_a_path_token_is_not_extended_by_a_longer_path
    assert_match FastCert.token_regexp("bin/task"), "runs bin/task begin\n"
    refute_match FastCert.token_regexp("bin/task"), "runs bin/task-archive begin\n"
    refute_match FastCert.token_regexp("bin/task"), "loads bin/task.rb\n"
    refute_match FastCert.token_regexp("bin/release"), "loads bin/release.rb\n"
    refute_match FastCert.token_regexp("config/queue.yml"), "config/queue.yml.erb\n"
    assert_match FastCert.token_regexp("config/queue.yml"), "YAML.load_file('config/queue.yml')\n"
  end

  # A constant keeps the word boundary and MUST: a trailing dot is the canonical
  # usage, so the path rule's stricter edge would reject every real call site.
  def test_a_constant_token_still_allows_a_trailing_call
    assert_match FastCert.token_regexp("News::Review"), "News::Review.new(news).call\n"
    refute_match FastCert.token_regexp("News::Review"), "NewsX::Review\n"
    refute_match FastCert.token_regexp("News::Review"), "News::Reviewer.new\n"
  end

  # --- restraint: what must NOT change ------------------------------------------

  # A source with an EXISTING convention twin never reaches any of the above. This
  # is the branch 1844 of the hub's 1928 sources take, and it is byte-identical.
  def test_a_source_with_an_existing_twin_is_untouched_by_the_grep_rules
    with_tree(
      "app/models/gate_run.rb" => "class GateRun; end\n",
      "test/models/gate_run_test.rb" => "class A; end\n",
      "test/models/gate_run_wiring_test.rb" => "# a sibling in a MIRRORED namespace\n",
      "test/integration/gate_run_flow_test.rb" => "GateRun.create!\n"
    ) do |dir|
      # Only the twin. test/models/ mirrors app/models/ one-to-one, so no family
      # hop applies there, and the grep never fires because the twin exists.
      assert_equal ["test/models/gate_run_test.rb"],
                   FastCert.select_tests(dir, ["app/models/gate_run.rb"])
    end
  end

  def test_unmappable_paths_still_have_no_grep_at_all
    assert_empty FastCert.grep_tokens(REPO_ROOT, "app/views/tasks/_gates.html.erb")
    assert_empty FastCert.grep_tokens(REPO_ROOT, "docs/agents/sop.md")
    assert_empty FastCert.grep_tokens(REPO_ROOT, "db/schema.rb").reject { |t| t == "Schema" }
  end

  # --- [integration] the real tree, where the defect was measured ----------------

  # THE HEADLINE NUMBER, pinned against the live repo rather than a fixture, because
  # a fixture cannot show that the 325 were real. Bounded rather than exact: the set
  # is 8 files today and will move as tools grow test files, but it must never again
  # be a number that only a full suite could run.
  def test_bin_task_maps_to_a_defensible_set_in_this_repo
    mapped = FastCert.select_tests(REPO_ROOT, ["bin/task"])

    refute_empty mapped, "bin/task must map to something — it has a harness family"
    assert_operator mapped.size, :<=, FastCert::DEFAULT_MAPPED_CAP,
                    "bin/task mapped #{mapped.size} test files (was 325 on the bare word " \
                    "\"task\"); the mapped lane caps at #{FastCert::DEFAULT_MAPPED_CAP}"
    mapped.each do |t|
      assert_match(%r{\Atest/(?:lib|commands)/task_}, t,
                   "#{t} is not named after bin/task")
    end
    refute_includes mapped, "test/models/task_test.rb"
  end

  # The other end of the same defect: a config file whose camelized basename was an
  # English word matched a third of the suite.
  def test_test_environment_config_maps_narrowly_in_this_repo
    mapped = FastCert.select_tests(REPO_ROOT, ["config/environments/test.rb"])

    assert_operator mapped.size, :<=, FastCert::DEFAULT_MAPPED_CAP,
                    "config/environments/test.rb mapped #{mapped.size} test files " \
                    "(was 208 on the token \"Test\")"
  end

  # The registry enumerating every bin script must stay reachable from a script with no harness
  # test of its own: it is their only mapped evidence, carried by the quoted-name spelling.
  # ASSERTED, NOT SKIPPED, if the registry is missing: this file runs against the hub so the
  # condition cannot fire, and a skip is what config/test_health.yml ratchets against. Deleted
  # means red.
  # History: task grep-maps-three-hundred-tests.
  def test_the_bin_registry_stays_reachable_from_a_family_less_script
    registry = "test/lib/bin_help_flag_class_test.rb"

    assert File.file?(File.join(REPO_ROOT, registry)),
           "#{registry} is the only mapped evidence a family-less bin script has"
    assert_includes FastCert.select_tests(REPO_ROOT, ["bin/island-background"]), registry
  end

  # THE WIRING INITIALIZER, which is the diff this whole clause exists for. Its class
  # half (lib/middleware/edge_guard.rb) still maps them, so the hole only opens
  # on a diff touching the initializer ALONE — which is exactly the diff a wiring
  # change produces, and it mapped to ZERO.
  #
  # ASSERTED, NOT SKIPPED, if a file is missing: this test lives in the hub and runs
  # against the hub, so the condition cannot fire, and a skip is coverage switched off
  # while keeping the test's name.
  def test_the_edge_guard_initializer_maps_every_test_asserting_its_wiring_in_this_repo
    initializer = "config/initializers/edge_guard.rb"
    owner = "lib/middleware/edge_guard.rb"

    assert File.file?(File.join(REPO_ROOT, initializer)), "#{initializer} is the subject here"
    assert File.file?(File.join(REPO_ROOT, owner)),
           "#{owner} is what QUALIFIES the EdgeGuard constant; without it the token is dropped"

    # THIS FILE IS SUBTRACTED, and only this file. It has to write the initializer's
    # path to assert anything about it, so it names the subject and the grep rightly
    # finds it — a self-reference, not a false positive. Subtracting it keeps the
    # assertion EXACT about the repo instead of loosening it to assert_includes, which
    # would go green on a mapping that had grown a hundred coincidental matches.
    mapped = FastCert.select_tests(REPO_ROOT, [initializer]) - [SELF]

    # canonical_host_wiring_test.rb earns its place rather than coinciding into it: it
    # asserts CanonicalHost sits BEHIND EdgeGuard, so un-mounting EdgeGuard or moving it
    # off position 0 turns that test red, and a diff touching this initializer alone
    # should run it. Grow this list only for an entry that genuinely asserts the wiring
    # — a coincidental token match is the thing assert_equal exists to catch.
    # client_ip_spoof_test.rb earns its place the same way: its armed-guard cases build
    # EdgeGuard ahead of RemoteIp and Rack::Attack and assert what each reader sees.
    assert_equal ["test/integration/canonical_host_wiring_test.rb",
                  "test/integration/client_ip_spoof_test.rb",
                  "test/integration/edge_guard_wiring_test.rb",
                  "test/lib/edge_guard_test.rb"],
                 mapped,
                 "the wiring initializer alone must reach every test that asserts its wiring"
  end

  # THE CONTRACT TEST OF A CONFIG, reached through the quoted basename. It names its
  # subject at rails_lane_contract_test.rb:33 as
  # `File.join(ROOT, "config", "rails_lane.yml")` — split, so the path token cannot
  # see it, and it is the one test that exists to assert that config's contract.
  def test_a_config_contract_test_is_reachable_from_its_own_config_in_this_repo
    contract = "test/lib/rails_lane_contract_test.rb"

    assert File.file?(File.join(REPO_ROOT, contract)), "#{contract} is the subject here"
    assert_includes FastCert.select_tests(REPO_ROOT, ["config/rails_lane.yml"]), contract

    guard = "test/lib/qa_registry_app_host_test.rb"

    assert File.file?(File.join(REPO_ROOT, guard)), "#{guard} is the subject here"
    assert_includes FastCert.select_tests(REPO_ROOT, ["config/qa_environments.yml"]), guard
  end

  # THE BLAST RADIUS: every config source in the repo is swept, not sampled, because over-widening
  # shows up as a source alone mapping over the cap. THE SWEEP COUNTS WHAT IT READ: if the glob or
  # filter returns nothing, an assertion inside the loop never runs and the test passes having
  # proved nothing. The floor below is what makes a green run mean something.
  # History: task config-sources-lose-their-tests.
  def test_no_config_source_in_this_repo_maps_over_the_cap
    over = config_sources.filter_map do |path|
      n = FastCert.select_tests(REPO_ROOT, [path]).size
      [path, n] if n > FastCert::DEFAULT_MAPPED_CAP
    end

    # THE COUNT TRACKS THE TREE: it moves whenever a test file spelling this config's path is added
    # or stops citing it, and is not a property of the mapping rule. The freeze pushes new tests
    # into new files whose headers cite this config to say why, which the mapper is supposed to
    # follow. A frozen hotspot deliberately does NOT spell the path: naming its ceiling in words
    # buys the same and costs this lane no file. The assertion is FOR the LIST: this one known entry
    # and no other. A second path appearing is the regression; this number changing is bookkeeping.
    # History: task wire-task-dependencies-field.
    expected = ["config/test_health.yml (24)"]

    # THE FAILURE NAMES THE SPELLING, not just the count: a new test file spelling a config's path
    # can redden this from a diff touching neither the config nor the mapper. #spelling_diagnosis
    # lists every file answering to each token, so the reader finds theirs, and states the remedy.
    # BUILT ONLY FOR THE UNEXPECTED ENTRIES, so a passing run pays nothing: `over` equals `expected`
    # on green and the map below walks an empty array.
    # History: task mapped-cap-lacks-margin.
    assert_equal expected, over.map { |path, n| "#{path} (#{n})" },
                 "config/test_health.yml was already over the cap before this clause " \
                 "existed (its PATH matches 24 files); any OTHER entry here means the " \
                 "config spelling re-opened a cap trip" +
                 over.reject { |path, n| expected.include?("#{path} (#{n})") }
                     .map { |path, _| "\n\n#{spelling_diagnosis(path)}" }.join
  end

  # THE MARGIN, PINNED WHERE THE READER IS. At the cap the mapped lane goes from "runs 15" to
  # "runs 0, still green". bin/fast-check warns only for a diff CONTAINING the at-cap subject, so
  # this sweep, which that builder's CI reddens, flags a config ENTERING the band before it goes
  # quiet. NAMED BY BASENAME, NOT COSMETIC: a full path here adds this file to that config's
  # mapped set; `"release_x.yml (15)"` is neither #grep_tokens token. The over-cap sweep above
  # keeps full paths. THE BAND RULE IS ASKED of FastCert.cap_decision, not restated. The cap is
  # passed explicitly so an exported FAST_CHECK_MAPPED_CAP cannot move the pin.
  # History: task mapped-cap-lacks-margin.
  def test_no_config_source_sits_inside_the_cap_margin_unannounced
    near = config_sources.filter_map do |path|
      tests = FastCert.select_tests(REPO_ROOT, [path])
      [path, tests.size] if FastCert.cap_decision(tests, {}, cap: FastCert::DEFAULT_MAPPED_CAP)[:approaching]
    end

    # release_repos.yml went 15 → 13 on 2026-09-24: two cert-route test files that
    # spelled its path retired with the routes (/tasks/dor-reads-settled-ci-verdict).
    # Both left the band the same day when the local cert evidence system retired
    # (/tasks/retire-local-cert-evidence) and took the tests that spelled them.
    expected = []

    # WHAT THE ASSERTION IS FOR is the LIST, exactly as the over-cap sweep above: a NEW
    # entry is the thing to act on, a number moving on an entry already here is
    # bookkeeping. Acting on it means taking the spelling back out — cite the constant
    # — never raising the cap, which only moves the cliff.
    assert_equal expected, near.map { |path, n| "#{File.basename(path)} (#{n})" },
                 "these config sources are within #{FastCert::DEFAULT_MAPPED_MARGIN} mapped " \
                 "path(s) of the cap of #{FastCert::DEFAULT_MAPPED_CAP}: one or two more test " \
                 "files naming one of them and its mapped lane runs ZERO tests while still " \
                 "reporting green" +
                 near.reject { |path, n| expected.include?("#{File.basename(path)} (#{n})") }
                     .map { |path, _| "\n\n#{spelling_diagnosis(path)}" }.join
  end

  private

  # THE SWEEP'S POPULATION, shared by both cap sweeps so they cannot drift apart about
  # what a config source is — and carrying the floor, because a source-scanning test is
  # exit-blind: if the glob ever returns nothing, every assertion inside the loop is
  # skipped and the test passes having proved nothing.
  def config_sources
    configs = `git -C #{REPO_ROOT} ls-files`.split("\n")
                                            .grep(%r{\Aconfig/.+\.(?:ya?ml|rb)\z})

    assert_operator configs.size, :>=, 40,
                    "swept #{configs.size} config sources — too few to be the real tree"
    configs
  end

  # WHAT A CAP TRIP OWES ITS FINDER: the token that reached the subject, every test
  # file that answers to it, and the one edit that takes a file back out of the set.
  #
  # THE REMEDY IS MEASURED, not read off the mapper's source: a test that names the
  # release registry through Release::Repos::CONFIG_PATH is NOT among the files that
  # config maps to, while every file that spells the path is.
  def spelling_diagnosis(path)
    lines = ["#{path} — the spellings that reach it:"]
    FastCert.spelling_breakdown(REPO_ROOT, path).each do |token, hits|
      lines << "  #{token.inspect} -> #{hits.size} test file(s)"
      hits.each { |hit| lines << "      #{hit}" }
    end
    lines << "  The file in YOUR diff is one of those. Take it back out by citing the " \
             "CONSTANT that names this path instead of spelling the path in prose, or " \
             "by naming the file without its directory. Do NOT raise " \
             "FastCert::DEFAULT_MAPPED_CAP: that moves the cliff without removing it"
    lines.join("\n")
  end
end
