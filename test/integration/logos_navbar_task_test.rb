require "test_helper"
require "rake"

# [integration] logos:navbar (task navbar-logo-generator): the rake task writes
# every Navbar Logo example and guide drawing for a brand as an SVG file and
# prints the paths; each file parses, and each logo is vector-only.
class LogosNavbarTaskTest < ActiveSupport::TestCase
  TASK = "logos:navbar".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    Rake::Task[TASK].reenable
    @dir = Dir.mktmpdir("logos-navbar")
  end

  teardown { FileUtils.remove_entry(@dir) }

  def run_task(*args) = capture_io { Rake::Task[TASK].invoke(*args) }

  test "writes every example and guide drawing for a brand, as parseable vector files" do
    out, = run_task("industries", @dir)
    paths = out.lines.map(&:strip)

    assert_equal 24, paths.size
    assert_equal Dir[File.join(@dir, "*.svg")].sort, paths.sort, "prints exactly the files it wrote"
    expected = [3, 4].product(%w[homogeneous first second], %w[light dark], ["", "-guides"]).map do |rule, text, tone, guides|
      "industries-rule#{rule}-#{text}-#{tone}#{guides}.svg"
    end
    assert_equal expected.sort, paths.map { |p| File.basename(p) }.sort

    paths.each do |path|
      xml = Nokogiri::XML(File.read(path)) { |config| config.strict }
      assert_empty xml.errors, path
      assert_equal "svg", xml.root.name
      assert_equal "http://www.w3.org/2000/svg", xml.root.namespace.href
      names = xml.xpath("//*").map(&:name).uniq.sort
      if path.end_with?("-guides.svg")
        assert_equal %w[g line path svg text], names, path
      else
        assert_equal %w[g path svg], names, "#{path} must be paths only"
        assert_match(/\A0 0 [\d.]+ 300\.00\z/, xml.root["viewBox"], path)
      end
      assert_empty xml.xpath("//@*[contains(name(), 'href')]"), "#{path} carries no external reference"
    end
  end

  test "writes under tmp/logos/<brand> by default" do
    out, = run_task("studio")
    dir = Rails.root.join("tmp/logos/studio")
    assert_equal 24, out.lines.size
    out.lines.each do |line|
      assert_equal dir.to_s, File.dirname(line.strip)
      assert File.size?(line.strip), line
    end
  end

  test "refuses an unknown or a missing brand and writes nothing" do
    [["acme", @dir], [nil, @dir]].each do |args|
      Rake::Task[TASK].reenable
      error = assert_raises(SystemExit) { capture_io { Rake::Task[TASK].invoke(*args) } }
      assert_equal 1, error.status
      assert_empty Dir.children(@dir)
    end
  end
end
