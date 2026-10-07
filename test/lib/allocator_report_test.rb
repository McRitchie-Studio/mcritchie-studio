require "test_helper"

# hub-web-memory-stays-under: pins the allocator choice (jemalloc via LD_PRELOAD
# from the heroku-26 stack image) and the boot report that proves it took effect.
class AllocatorReportTest < ActiveSupport::TestCase
  ROOT = Rails.root
  PLAN_DOC = ROOT.join("docs/agents/system/web-memory-allocator.md")

  setup do
    @dir = Dir.mktmpdir("allocator-report")
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  test "[unit] a process that mapped libjemalloc reports jemalloc" do
    maps = write_maps("7f00-7f01 r-xp 00000000 08:01 1 #{AllocatorReport::JEMALLOC_PATH}\n")
    report = AllocatorReport.current(env: { "LD_PRELOAD" => AllocatorReport::JEMALLOC_PATH,
                                            "MALLOC_ARENA_MAX" => "2" },
                                     maps_path: maps, mainlibs: "-lz -lpthread")

    assert_equal "jemalloc", report[:allocator]
    assert_equal AllocatorReport::JEMALLOC_PATH, report[:ld_preload]
    assert_equal "2", report[:malloc_arena_max]
  end

  test "[unit] LD_PRELOAD set but not mapped reports glibc, because ENV is not the truth" do
    maps = write_maps("7f00-7f01 r-xp 00000000 08:01 1 /usr/lib/x86_64-linux-gnu/libc.so.6\n")
    report = AllocatorReport.current(env: { "LD_PRELOAD" => "/gone/libjemalloc.so.2" },
                                     maps_path: maps, mainlibs: "")

    assert_equal "glibc", report[:allocator]
  end

  test "[unit] no /proc (a Mac desk) reports unknown; a jemalloc-linked Ruby reports jemalloc" do
    missing = File.join(@dir, "nope")

    assert_equal "unknown", AllocatorReport.current(env: {}, maps_path: missing, mainlibs: "")[:allocator]
    assert_equal "jemalloc", AllocatorReport.current(env: {}, maps_path: missing, mainlibs: "-ljemalloc")[:allocator]
  end

  test "[unit] the boot line is one grep-able line with every field" do
    line = AllocatorReport.line(allocator: "jemalloc", ld_preload: "/x.so", malloc_arena_max: nil, malloc_conf: nil)

    assert_match(/\A\[allocator\] allocator=jemalloc ld_preload=\/x\.so malloc_arena_max=- malloc_conf=- pid=\d+\z/, line)
  end

  test "[integration] the production boot logs the allocator line through the initializer" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    initializer = ROOT.join("config/initializers/allocator_report.rb").read

    assert_includes initializer, "AllocatorReport.log_boot(Rails.logger) if Rails.env.production?"
    AllocatorReport.log_boot(logger)
    assert_match(/^\[allocator\] allocator=(jemalloc|glibc|unknown) /, io.string)
  end

  test "[integration] the release-lane command, the code and the plan agree on one jemalloc path" do
    doc = PLAN_DOC.read
    command = "heroku config:set LD_PRELOAD=#{AllocatorReport::JEMALLOC_PATH} -a mcritchie-studio"

    assert_includes doc, command, "the plan doc must carry the exact production command"
    assert_includes doc, "heroku config:unset LD_PRELOAD -a mcritchie-studio", "and its rollback"
    assert_equal "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2", AllocatorReport::JEMALLOC_PATH
  end

  test "[integration] the boot environment in code never pins WEB_CONCURRENCY=1 or its own LD_PRELOAD" do
    # The allocator is a Heroku config var (reversible with one unset), so no
    # checked-in boot file may set it, and the 2026-08-09 H12 lesson stands.
    %w[Procfile app.json config/puma.rb].each do |path|
      file = ROOT.join(path)
      next unless file.exist?

      body = file.read
      refute_match(/WEB_CONCURRENCY["']?\s*[:=]>?\s*["']?1\b/, body, "#{path} must not pin WEB_CONCURRENCY=1")
      refute_match(/LD_PRELOAD\s*=/, body, "#{path} must not set LD_PRELOAD; it is a config var")
    end
  end

  private

  def write_maps(content)
    path = File.join(@dir, "maps")
    File.write(path, content)
    path
  end
end
