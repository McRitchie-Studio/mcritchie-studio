# frozen_string_literal: true

# [unit] bin/ui-lint and bin/lib/ui_lint.rb: the five front-end house rules,
# counted over a repo tree's templates, reported and never enforced unless --strict.
#
# Each rule has a fixture pair under test/fixtures/files/ui_lint/: <rule>.html.erb
# carries the offenses the rule must flag (and how many), <rule>_clean.html.erb the
# near misses it must not (a commented-out offense, a token class, a nonced script,
# a JSON data block, a short x-data). A clean twin is clean of EVERY rule, so a rule
# that starts matching its neighbours' near misses fails here too.
#
#   ruby -Itest test/lib/ui_lint_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "../../bin/lib/ui_lint"

class UiLintTest < Minitest::Test
  REPO = File.expand_path("../..", __dir__)
  BIN = File.join(REPO, "bin", "ui-lint")
  FIXTURES = File.join(REPO, "test", "fixtures", "files", "ui_lint")

  # How many offenses each flagged sample carries, for its own rule.
  FLAGGED = {
    "inline_style" => 3,
    "raw_hex" => 3,
    "px_utility" => 3,
    "unnonced_script" => 3,
    "long_x_data" => 2
  }.freeze

  def config = UiLint.load_config

  def offenses_in(name, cfg = config)
    UiLint.check(File.read(File.join(FIXTURES, name)), name, cfg)
  end

  def run_bin(*args, chdir: REPO, env: {})
    out, status = Open3.capture2e({ "UI_LINT_CHANGED_FILES" => nil }.merge(env), RbConfig.ruby, BIN, *args, chdir: chdir)
    [out, status.exitstatus]
  end

  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), body)
      end
      yield dir
    end
  end

  # --- the rules, one fixture pair each ----------------------------------------------

  def test_the_rule_list_is_the_five_house_rules_and_each_has_a_fixture_pair
    assert_equal FLAGGED.keys, UiLint::RULES
    UiLint::RULES.each do |rule|
      assert File.file?(File.join(FIXTURES, "#{rule}.html.erb")), "#{rule} has no flagged sample"
      assert File.file?(File.join(FIXTURES, "#{rule}_clean.html.erb")), "#{rule} has no clean twin"
    end
  end

  FLAGGED.each do |rule, count|
    define_method("test_#{rule}_flags_its_sample") do
      found = offenses_in("#{rule}.html.erb").select { |o| o.rule == rule }
      assert_equal count, found.size, "#{rule} on its sample: #{found.map { |o| "#{o.line} #{o.snippet}" }.inspect}"
    end

    define_method("test_#{rule}_passes_its_clean_twin") do
      found = offenses_in("#{rule}_clean.html.erb")
      assert_empty found, "the clean twin of #{rule} carries no offense of any rule: " \
                          "#{found.map { |o| "#{o.rule}@#{o.line} #{o.snippet}" }.inspect}"
    end
  end

  def test_each_flagged_offense_carries_its_real_line
    lines = offenses_in("unnonced_script.html.erb").map(&:line)
    assert_equal [1, 2, 3], lines
    source = "<%# a comment\n spanning\n three lines %>\n<div style=\"x\"></div>\n"
    assert_equal [4], UiLint.check(source, "x.html.erb", config).map(&:line),
                 "blanking a comment keeps its newlines, so the offense below it keeps its line"
  end

  def test_the_x_data_length_comes_from_the_config
    tight = config.merge("rules" => config["rules"].merge("long_x_data" => { "max_length" => 10 }))
    assert_equal 1, offenses_in("long_x_data_clean.html.erb", tight).count { |o| o.rule == "long_x_data" },
                 "at a 10-character limit `{ open: false }` (15) is long and `dropdown` (8) is not"
  end

  def test_a_hex_in_a_style_value_counts_as_both_a_style_and_a_hex
    found = UiLint.check(%(<p style="color: #fff; border-color: #112233">x</p>\n), "x.html.erb", config)
    assert_equal({ "inline_style" => 1, "raw_hex" => 2 }, found.map(&:rule).tally)
  end

  def test_an_erb_tag_with_its_own_quotes_stays_inside_the_class_value
    source = %(<div class="<%= on ? "bg-[#000]" : "p-2" %> rounded">x</div>\n)
    assert_equal ["raw_hex"], UiLint.check(source, "x.html.erb", config).map(&:rule)
  end

  # --- which files: the include globs and the path exemptions ------------------------

  # app/views/studio/emails/ is the engine's /admin/emails pages, rendered in the
  # host's application layout: app pages, so they are scanned.
  def test_mailer_views_and_svgs_are_exempt_by_path_and_nothing_else_is
    styled = %(<div style="color: #fff">x</div>\n)
    with_tree(
      "app/views/pages/home.html.erb" => styled,
      "app/views/user_mailer/welcome.html.erb" => styled,
      "app/views/studio/newsletter_mailer/issue.html.erb" => styled,
      "app/views/studio/mailers/_banner.html.erb" => styled,
      "app/views/layouts/mailer.html.erb" => styled,
      "app/views/studio/emails/index.html.erb" => styled,
      "app/views/icons/logo.svg.erb" => styled,
      "app/components/card_component.html.erb" => styled,
      "app/views/emails/not_a_mailer.html.erb" => styled
    ) do |dir|
      scanned, exempt = UiLint.files(dir, config)
      assert_equal %w[app/components/card_component.html.erb app/views/emails/not_a_mailer.html.erb
                      app/views/pages/home.html.erb app/views/studio/emails/index.html.erb], scanned
      assert_equal 5, exempt.size, exempt.inspect
    end
  end

  def test_every_exemption_in_the_config_is_a_path_glob
    Array(config["exempt"]).each do |pattern|
      assert_kind_of String, pattern
      assert_match(%r{\A(?:app/|\*\*/)}, pattern, "an exemption names a path, rooted at app/ or **/")
    end
  end

  # --- the report --------------------------------------------------------------------

  def test_the_report_prints_rule_totals_top_files_and_the_diff
    with_tree(
      "app/views/a.html.erb" => %(<div style="x"></div>\n<p class="text-[9px]"></p>\n),
      "app/views/b.html.erb" => %(<script>1</script>\n)
    ) do |dir|
      report = UiLint.scan(dir, config)
      text = UiLint.render(report, changed: ["app/views/b.html.erb", "README.md"]).join("\n")
      assert_match(/inline_style\s+1\s+1/, text)
      assert_match(/px_utility\s+1\s+1/, text)
      assert_match(/unnonced_script\s+1\s+1/, text)
      assert_match(/total\s+3\s+2/, text)
      assert_match(%r{top 2 file\(s\) of 2.*\n\s+2\s+app/views/a\.html\.erb}m, text, "most offenses first")
      assert_match(%r{diff: 2 changed file\(s\), 1 scanned template\(s\), 1 offense\(s\) in 1 file\(s\)\n\s+1\s+app/views/b\.html\.erb}, text)
    end
  end

  def test_no_known_diff_is_said_never_shown_as_an_empty_one
    with_tree("app/views/a.html.erb" => "<p></p>\n") do |dir|
      text = UiLint.render(UiLint.scan(dir, config), changed: nil).join("\n")
      assert_match(/diff: none known/, text)
    end
  end

  # --- the CLI: report-only, any tree, any cwd ---------------------------------------

  def test_the_cli_reports_and_exits_zero_whatever_it_finds
    with_tree("app/views/a.html.erb" => %(<div style="x"></div>\n)) do |dir|
      out, code = run_bin(dir, "--changed", "app/views/a.html.erb")
      assert_equal 0, code, out
      assert_match(/inline_style\s+1/, out)
      assert_match(/report only, nothing is enforced/, out)
    end
  end

  def test_strict_exits_one_on_an_offense_and_zero_on_a_clean_tree
    with_tree("app/views/a.html.erb" => %(<div style="x"></div>\n)) do |dir|
      out, code = run_bin(dir, "--strict")
      assert_equal 1, code, out
      assert_match(/--strict and 1 offense/, out)
    end
    with_tree("app/views/a.html.erb" => %(<div class="p-2"></div>\n)) do |dir|
      _, code = run_bin(dir, "--strict")
      assert_equal 0, code
    end
  end

  def test_another_trees_views_are_linted_from_any_cwd_with_the_hubs_config
    with_tree("app/views/x.html.erb" => %(<p class="w-[320px]"></p>\n)) do |dir|
      Dir.mktmpdir do |elsewhere|
        out, code = run_bin(dir, "--verbose", chdir: elsewhere)
        assert_equal 0, code, out
        assert_match(%r{app/views/x\.html\.erb:1\s+px_utility\s+w-\[320px\]}, out)
      end
    end
  end

  def test_the_diff_can_arrive_in_the_environment
    with_tree("app/views/a.html.erb" => %(<div style="x"></div>\n)) do |dir|
      out, = run_bin(dir, env: { "UI_LINT_CHANGED_FILES" => "app/views/a.html.erb\nGemfile" })
      assert_match(/diff: 2 changed file\(s\), 1 scanned template\(s\), 1 offense/, out)
    end
  end

  def test_an_unknown_flag_and_a_missing_tree_are_usage_errors
    _, code = run_bin("--bogus")
    assert_equal 2, code
    _, code = run_bin("/nonexistent/tree")
    assert_equal 2, code
  end

  def test_help_prints_usage_and_scans_nothing
    out, code = run_bin("--help")
    assert_equal 0, code
    assert_match(/Usage: bin\/ui-lint/, out)
    refute_match(/rule\s+offenses/, out)
  end

  def test_the_hubs_own_app_views_completes_and_prints_counts
    out, code = run_bin(REPO, "--changed", "")
    assert_equal 0, code, out
    assert_match(/(\d+) template\(s\) scanned/, out)
    assert_operator out[/(\d+) template\(s\) scanned/, 1].to_i, :>, 100, "the hub has hundreds of templates"
    UiLint::RULES.each { |rule| assert_match(/^\s+#{rule}\s+\d+\s+\d+$/, out, "a count line for #{rule}") }
    assert_match(/top \d+ file\(s\) of \d+ with an offense/, out)
  end

  # --- the fast-check advisory lane's two decisions ----------------------------------

  def test_the_advisory_lane_applies_only_to_a_tree_with_templates
    with_tree("app/views/a.html.erb" => "<p></p>\n") { |dir| assert UiLint.applies_to?(dir) }
    with_tree("app/components/a.html.erb" => "<p></p>\n") { |dir| assert UiLint.applies_to?(dir) }
    with_tree("lib/a.rb" => "1\n") { |dir| refute UiLint.applies_to?(dir) }
  end

  def test_the_advisory_command_runs_this_hubs_ui_lint_against_the_given_root
    cmd = UiLint.advisory_command("/some tree")
    assert_equal "#{BIN} /some\\ tree", cmd
  end
end
