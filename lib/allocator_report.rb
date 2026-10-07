# frozen_string_literal: true

# Reports which malloc the running Ruby process is actually using, so a
# Heroku config change to the allocator is verifiable from the logs instead of
# assumed (hub-web-memory-stays-under; plan in
# docs/agents/system/web-memory-allocator.md).
#
# Measured 2026-10-06 inside a mcritchie-studio one-off dyno (heroku-26 stack):
#   * MALLOC_ARENA_MAX=2 is ALREADY set, by the heroku/ruby buildpack's
#     .profile.d/ruby.sh (`export MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-2}`), so
#     "try MALLOC_ARENA_MAX=2" is the status quo, not a remedy.
#   * libjemalloc2 5.3.0 ships in the stack image at JEMALLOC_PATH, and
#     LD_PRELOAD of it maps into a Ruby process. No buildpack or Aptfile needed.
#
# The truth source is /proc/self/maps, not ENV: an LD_PRELOAD naming a missing
# file (say, after a stack upgrade moves the library) is ignored by ld.so with a
# warning, and the process silently runs glibc. The maps read catches that.
module AllocatorReport
  JEMALLOC_PATH = "/usr/lib/x86_64-linux-gnu/libjemalloc.so.2"
  MAPS_PATH = "/proc/self/maps"
  LOG_PREFIX = "[allocator]"

  module_function

  # => { allocator: "jemalloc" | "glibc" | "unknown", ld_preload:, malloc_arena_max:, malloc_conf: }
  def current(env: ENV, maps_path: MAPS_PATH, mainlibs: RbConfig::CONFIG["MAINLIBS"].to_s)
    {
      allocator: detect(maps_path, mainlibs),
      ld_preload: env["LD_PRELOAD"].presence,
      malloc_arena_max: env["MALLOC_ARENA_MAX"].presence,
      malloc_conf: env["MALLOC_CONF"].presence
    }
  end

  def detect(maps_path, mainlibs)
    return "jemalloc" if mainlibs.include?("jemalloc") # Ruby built --with-jemalloc
    return "unknown" unless File.readable?(maps_path)   # not Linux (a Mac desk)

    File.foreach(maps_path).any? { |line| line.include?("libjemalloc") } ? "jemalloc" : "glibc"
  rescue SystemCallError
    "unknown"
  end

  # One grep-able line: `heroku logs -a mcritchie-studio | grep '\[allocator\]'`.
  def line(report = current)
    fields = report.map { |key, value| "#{key}=#{value || '-'}" }.join(" ")
    "#{LOG_PREFIX} #{fields} pid=#{Process.pid}"
  end

  def log_boot(logger)
    logger&.info(line)
  end
end
