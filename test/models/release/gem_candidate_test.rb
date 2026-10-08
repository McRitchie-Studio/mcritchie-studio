require "test_helper"
require "rubygems/package"

# The release candidate a gem publishes for QA, and the comparison the ship makes
# before it publishes the final.
class Release::GemCandidateTest < ActiveSupport::TestCase
  C = Release::GemCandidate

  test "a candidate names its final and its number" do
    assert_equal "0.96.0.rc2", C.version("0.96.0", 2)
    assert C.candidate?("0.96.0.rc2")
    assert_equal "0.96.0", C.final_of("0.96.0.rc2")
    assert_equal 2, C.number_of("0.96.0.rc2")
    assert_equal "rc-0.96.0.rc2", C.tag("0.96.0.rc2")
  end

  test "a final, a beta and a two-segment version are not candidates" do
    %w[0.96.0 0.96.0.beta1 0.96.rc1 0.96.0.rc 0.96.0.rc1.1].each { |v| assert_not C.candidate?(v), v }
    assert_nil C.final_of("0.96.0")
  end

  test "a candidate tag never matches the v* pattern the allocation reads" do
    assert_not File.fnmatch("v*", C.tag("0.96.0.rc1"))
  end

  # --- plan ---

  test "the first sweep publishes rc1" do
    plan = C.plan(final: "0.96.0", live: %w[0.95.0], tip_tags: [], all_tags: [])
    assert plan.publish?
    assert_equal "0.96.0.rc1", plan.version
  end

  test "a re-run at the same tip reuses the live candidate tagged there" do
    plan = C.plan(final: "0.96.0", live: [{ "number" => "0.96.0.rc1" }], tip_tags: %w[rc-0.96.0.rc1], all_tags: %w[rc-0.96.0.rc1])
    assert plan.reuse?
    assert_equal "0.96.0.rc1", plan.version
  end

  # A QA bounce: the fix moves the tip, so the old candidate is another tree's.
  test "a moved tip gets the next number and never the old candidate" do
    plan = C.plan(final: "0.96.0", live: %w[0.96.0.rc1], tip_tags: [], all_tags: %w[rc-0.96.0.rc1])
    assert plan.publish?
    assert_equal "0.96.0.rc2", plan.version
  end

  # A crash between the push and the tag leaves a live candidate nobody can place.
  test "a live candidate with no tag is skipped, not reused" do
    plan = C.plan(final: "0.96.0", live: %w[0.96.0.rc1], tip_tags: [], all_tags: [])
    assert_equal "0.96.0.rc2", plan.version
  end

  # A yanked candidate is absent from the listing; its number can never be pushed again.
  test "a tagged candidate that is not live is skipped, never pushed again" do
    plan = C.plan(final: "0.96.0", live: [], tip_tags: %w[rc-0.96.0.rc1], all_tags: %w[rc-0.96.0.rc1])
    assert plan.publish?
    assert_equal "0.96.0.rc2", plan.version
  end

  test "a live final needs no candidate" do
    plan = C.plan(final: "0.96.0", live: %w[0.96.0 0.96.0.rc1], tip_tags: %w[rc-0.96.0.rc1], all_tags: %w[rc-0.96.0.rc1])
    assert plan.final_live?
    assert_equal "0.96.0", plan.version
  end

  test "another version's candidates do not move this one's number" do
    plan = C.plan(final: "0.96.0", live: %w[0.95.0.rc1 0.95.0.rc2 0.95.0], tip_tags: [], all_tags: %w[rc-0.95.0.rc2])
    assert_equal "0.96.0.rc1", plan.version
  end

  # --- rewrite_version ---

  test "the candidate build rewrites the one version literal" do
    text = %(module Studio\n  VERSION = "0.96.0"\nend\n)
    assert_equal %(module Studio\n  VERSION = "0.96.0.rc1"\nend\n), C.rewrite_version(text, "0.96.0", "0.96.0.rc1")
  end

  test "a version file that does not declare the final is refused" do
    assert_nil C.rewrite_version(%(VERSION = "0.95.0"\n), "0.96.0", "0.96.0.rc1")
    assert_nil C.rewrite_version(%(VERSION = "0.96.0"\nOLD_VERSION = "0.96.0"\n), "0.96.0", "0.96.0.rc1")
    assert_nil C.rewrite_version(%(VERSION = "0.96.0"\n), "0.96.0", "0.97.0.rc1")
  end

  # --- manifest and differences, over real built gems ---

  def build_gem(dir, version, files)
    FileUtils.mkdir_p(File.join(dir, "lib/probe"))
    files.each { |path, body| File.write(File.join(dir, path), body) }
    File.write(File.join(dir, "lib/probe/version.rb"), %(module Probe\n  VERSION = "#{version}"\nend\n))
    spec = Gem::Specification.new do |s|
      s.name = "pgaq-probe"
      s.version = version
      s.summary = "probe"
      s.authors = ["test"]
      s.files = files.keys + ["lib/probe/version.rb"]
      s.add_dependency "rake", ">= 13"
      yield s if block_given?
    end
    out = File.join(dir, "pgaq-probe-#{version}.gem")
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { Dir.chdir(dir) { Gem::Package.build(spec, true, false, out) } }
    out
  end

  def manifest_of(version, files, &block)
    Dir.mktmpdir("candidate-test") do |dir|
      C.manifest(build_gem(dir, version, files, &block), version_file: "lib/probe/version.rb")
    end
  end

  FILES = { "lib/probe.rb" => "module Probe; end\n" }.freeze

  test "a candidate and a final built from one tree carry the same contents" do
    candidate = manifest_of("0.2.0.rc1", FILES)
    final     = manifest_of("0.2.0", FILES)

    assert_equal "0.2.0.rc1", candidate["version"]
    assert_equal [], C.differences(candidate, final)
  end

  test "a changed file is named" do
    found = C.differences(manifest_of("0.2.0.rc1", FILES), manifest_of("0.2.0", FILES.merge("lib/probe.rb" => "module Probe; X = 1; end\n")))
    assert_equal ["lib/probe.rb differs"], found
  end

  test "an added or missing file is named" do
    extra = FILES.merge("lib/extra.rb" => "1\n")
    assert_equal ["lib/extra.rb is only in the final"], C.differences(manifest_of("0.2.0.rc1", FILES), manifest_of("0.2.0", extra))
    assert_equal ["lib/extra.rb is only in the candidate"], C.differences(manifest_of("0.2.0.rc1", extra), manifest_of("0.2.0", FILES))
  end

  test "a changed dependency is named" do
    final = manifest_of("0.2.0", FILES) { |s| s.add_dependency "json", ">= 2" }
    assert_equal ["runtime or development dependencies differ"], C.differences(manifest_of("0.2.0.rc1", FILES), final)
  end

  # Only the version file is read with the version taken out.
  test "a version string in another file still counts as a difference" do
    a = manifest_of("0.2.0.rc1", FILES.merge("README.md" => "probe 0.2.0.rc1\n"))
    b = manifest_of("0.2.0", FILES.merge("README.md" => "probe 0.2.0\n"))
    assert_equal ["README.md differs"], C.differences(a, b)
  end

  # --- qa_candidate ---

  test "the candidate QA tested is the one every consumer locks" do
    assert_equal ["0.96.0.rc2", []], C.qa_candidate("0.96.0", "hub" => "0.96.0.rc2", "turf" => "0.96.0.rc2", "rolio" => nil)
  end

  test "consumers on the final itself name no candidate and no problem" do
    assert_equal [nil, []], C.qa_candidate("0.96.0", "hub" => "0.96.0")
  end

  test "a consumer on an older version is a problem" do
    candidate, problems = C.qa_candidate("0.96.0", "hub" => "0.96.0.rc1", "turf" => "0.95.0")
    assert_nil candidate
    assert_match(/turf locks 0\.95\.0/, problems.join)
  end

  test "consumers on different candidates are a problem" do
    candidate, problems = C.qa_candidate("0.96.0", "hub" => "0.96.0.rc1", "turf" => "0.96.0.rc2")
    assert_nil candidate
    assert_match(/different candidates/, problems.join)
  end

  test "a mix of the final and a candidate is a problem" do
    _, problems = C.qa_candidate("0.96.0", "hub" => "0.96.0.rc1", "turf" => "0.96.0")
    assert_match(/some consumers lock 0\.96\.0 and others a candidate/, problems.join)
  end
end
