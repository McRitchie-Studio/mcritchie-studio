# frozen_string_literal: true

# Guard: every hub spec that studio-engine's CI runs still exists in this tree.
#
# WHY. studio-engine's consumer-ci.yml has a `hub-browser` job that runs a listed subset
# of this repo's Playwright specs against each engine commit. The list lives in the
# engine (.github/hub-e2e-subset.txt), the files live here. Before this guard, a hub PR
# that renamed or deleted a listed spec went green here and turned the ENGINE's lane red
# later, in an engine PR whose author had touched nothing of the hub. This reads the
# list from the installed gem and fails the hub PR that breaks it, by path.
#
# The engine ships the list from the release after 0.115.3 (studio-engine.gemspec;
# guarded there by test/lib/consumer_ci_hub_browser_test.rb). On 0.115.3 and older the
# gem has no list, so the live check below asserts the version instead; once the lock
# moves past it, a missing list is red too.
#
# Run directly:
#   bundle exec ruby -Itest test/lib/hub_e2e_subset_guard_test.rb
#
# One tier here: [unit] the list reader and the missing-file check against fixtures,
# and the same check against the real list and this tree.

require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

class HubE2eSubsetGuardTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LIST_IN_GEM = ".github/hub-e2e-subset.txt"
  LAST_ENGINE_WITHOUT_LIST = Gem::Version.new("0.115.3")

  # The engine's own reader (bin/hub-e2e-subset read_list): `#` starts a comment,
  # blank lines are skipped, one hub-relative path per line.
  def self.listed(text) = text.lines.map { |l| l.sub(/#.*/, "").strip }.reject(&:empty?)
  def self.missing(paths, root) = paths.reject { |rel| File.file?(File.join(root, rel)) }

  def engine = Gem.loaded_specs.fetch("studio-engine")
  def list_path = File.join(engine.full_gem_path, LIST_IN_GEM)

  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), "")
      end
      yield dir
    end
  end

  def test_unit_the_reader_drops_comments_and_blank_lines
    text = "# header\n\ne2e/a.spec.js  # why\n  e2e/b.spec.js\n# e2e/commented.spec.js\n"
    assert_equal %w[e2e/a.spec.js e2e/b.spec.js], self.class.listed(text)
  end

  def test_unit_a_missing_spec_is_named
    with_tree(%w[e2e/a.spec.js]) do |root|
      assert_equal %w[e2e/renamed.spec.js], self.class.missing(%w[e2e/a.spec.js e2e/renamed.spec.js], root)
    end
  end

  def test_unit_a_directory_is_not_a_spec
    with_tree(%w[e2e/nested/a.spec.js]) do |root|
      assert_equal %w[e2e/nested], self.class.missing(%w[e2e/nested], root)
    end
  end

  def test_unit_every_spec_the_engine_runs_is_on_disk_here
    unless File.file?(list_path)
      assert_operator engine.version, :<=, LAST_ENGINE_WITHOUT_LIST,
                      "studio-engine #{engine.version} ships no #{LIST_IN_GEM}; every release after " \
                      "#{LAST_ENGINE_WITHOUT_LIST} must (its gemspec `files`)"
      return
    end

    paths = self.class.listed(File.read(list_path))
    refute_empty paths, "#{list_path} names no spec"
    gone = self.class.missing(paths, ROOT)
    assert_empty gone,
                 "studio-engine's hub-browser lane runs #{gone.join(', ')}, which this tree no longer has. " \
                 "A rename or delete here turns every engine PR red: repoint or drop the line in " \
                 "studio-engine's #{LIST_IN_GEM} in the same change."
  end
end
