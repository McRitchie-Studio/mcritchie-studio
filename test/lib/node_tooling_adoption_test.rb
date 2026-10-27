# frozen_string_literal: true

# [unit] The hub on studio-engine's Node tooling package (/tasks/hub-adopts-node-tooling):
#
# 1. The pins hold: Studio::NodeTooling.drift is what `bin/rails studio:node:check`
#    runs, so this is that check in the Rails lane.
# 2. No workflow hard-codes Node's major. The engine's check reads .tool-versions and
#    package.json only, so a `node-version: 20` in a workflow would slip past it.
# 3. node_tooling:link (lib/node_tooling_link.rb) links a plain checkout, and never
#    writes through a node_modules shared with another checkout, or on Heroku.
# 4. playwright.config.js and the node:test register build on the linked package.
#
# Plain Minitest, no Rails boot: it needs only the bundled gem's lib.
#   ruby -Itest test/lib/node_tooling_adoption_test.rb
require "bundler/setup"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require "yaml"
require "studio/node_tooling"
require_relative "../../lib/node_tooling_link"

class NodeToolingAdoptionTest < Minitest::Test
  ROOT = Pathname(File.expand_path("../..", __dir__))

  def self.test(name, &block) = define_method("test_#{name.gsub(/\W+/, "_")}", &block)

  test "the hub matches studio-engine's Node pins (studio:node:check)" do
    assert_equal [], Studio::NodeTooling.drift(ROOT)
    assert_equal "nodejs #{Studio::NodeTooling.versions.fetch("node")}", ROOT.join(".tool-versions").read.strip
  end

  test "every setup-node step reads .tool-versions and none hard-codes a bare major" do
    steps = Dir[ROOT.join(".github/workflows/*.yml")].flat_map do |file|
      YAML.safe_load_file(file).fetch("jobs", {}).flat_map do |job_name, job|
        Array(job["steps"]).grep(Hash).select { |s| s["uses"].to_s.start_with?("actions/setup-node") }
                           .map { |s| ["#{File.basename(file)} #{job_name}", s.fetch("with", {})] }
      end
    end
    assert_operator steps.size, :>=, 4, "expected the javascript, playwright, system and ui-budget setup-node steps"

    steps.each do |where, with|
      assert_includes with["node-version-file"].to_s, ".tool-versions", "#{where}: setup-node does not read .tool-versions"
      version = with["node-version"].to_s
      next if version.empty?

      # The reusable workflow keeps 22 for a CALLER with no .tool-versions, and only then.
      assert_match(/\A\$\{\{ hashFiles\('\.tool-versions'\) == '' && '\d+' \|\| '' \}\}\z/, version,
                   "#{where}: node-version #{version.inspect} pins Node outside .tool-versions")
    end
  end

  test "playwright.config.js and the node:test register load the linked shared package" do
    assert_match %r{"node_modules", "\.studio-engine"}, ROOT.join("playwright.config.js").read
    assert_match(/studioPlaywrightConfig\(/, ROOT.join("playwright.config.js").read)
    assert_match %r{node_modules/\.studio-engine/node_test/register\.mjs}, ROOT.join("test/javascript/support/register.mjs").read
    refute ROOT.join("test/javascript/support/importmap_hooks.mjs").exist?, "the hub's copy of the hook is retired"
  end

  # A stand-in for Studio::NodeTooling: the real root, a temp host.
  def tooling = Studio::NodeTooling

  test "a plain checkout gets its own link to the bundled gem" do
    Dir.mktmpdir do |dir|
      status, message = NodeToolingLink.call(root: dir, tooling: tooling, env: {})
      assert_equal :linked, status, message
      assert_equal tooling.root, Pathname(dir).join("node_modules/.studio-engine").readlink
      assert_equal :linked, NodeToolingLink.call(root: dir, tooling: tooling, env: {}).first, "relinking is idempotent"
    end
  end

  test "on Heroku it refuses and writes nothing" do
    Dir.mktmpdir do |dir|
      [{ "DYNO" => "web.1" }, { "STACK" => "heroku-26" }].each do |env|
        status, message = NodeToolingLink.call(root: dir, tooling: tooling, env: env)
        assert_equal :refused, status
        assert_match(/Heroku/, message)
      end
      refute Pathname(dir).join("node_modules").exist?
    end
  end

  test "a node_modules shared with the primary is never written through" do
    Dir.mktmpdir do |dir|
      primary = Pathname(dir).join("primary").tap(&:mkpath)
      primary.join("node_modules").mkpath
      desk = Pathname(dir).join("desk").tap(&:mkpath)
      File.symlink(primary.join("node_modules"), desk.join("node_modules"))

      status, message = NodeToolingLink.call(root: desk, tooling: tooling, env: {})
      assert_equal :refused, status
      assert_includes message, primary.realpath.to_s
      refute primary.join("node_modules/.studio-engine").symlink?, "the desk wrote the primary's link"

      tooling.link!(primary)
      status, message = NodeToolingLink.call(root: desk, tooling: tooling, env: {})
      assert_equal :shared, status, message
    end
  end

  test "a dangling node_modules symlink is refused with the fix" do
    Dir.mktmpdir do |dir|
      File.symlink(File.join(dir, "gone"), File.join(dir, "node_modules"))
      status, message = NodeToolingLink.call(root: dir, tooling: tooling, env: {})
      assert_equal :refused, status
      assert_match(/dangling/, message)
    end
  end
end
