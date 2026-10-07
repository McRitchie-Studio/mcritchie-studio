# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "fileutils"

# DevSecretKey: a local checkout's SECRET_KEY_BASE is a development key, never a
# production one.
#
# WHY THIS EXISTS. On 2026-10-06 all 23 local .env files that set SECRET_KEY_BASE
# (the hub and turf-monster primaries plus every desk cut from them) held the
# PRODUCTION mcritchie-studio key. Two steps put it there:
#
#   1. bin/ecosystem-build restored a primary's .env from `heroku config` of the
#      PRODUCTION app, SECRET_KEY_BASE included.
#   2. bin/agent-worktree copied the primary's .env into every new desk verbatim.
#
# Rails 8.1 development reads ENV["SECRET_KEY_BASE"] (measured: the app's key and
# the env key share a digest), so every local process signed cookies, magic links
# and API tokens that production would accept. Both writers now go through
# `rewrite`, and `scan` finds any file that still holds a production key.
#
# NEVER PRINTS A VALUE. Everything that leaves this module is a path, a state or a
# SHA-256 digest prefix. A full SHA-256 of a 512-bit random key does not reveal
# it, but only the 8-char prefix is ever shown, matching how the finding was
# reported.
module DevSecretKey
  KEY = "SECRET_KEY_BASE"
  # `SECRET_KEY_BASE=…` and `export SECRET_KEY_BASE=…`, leading space allowed.
  LINE = /\A(\s*(?:export\s+)?#{KEY}\s*=)(.*?)(\r?\n)?\z/m
  PREFIX_LEN = 8

  # Production Heroku apps whose SECRET_KEY_BASE a local file must never hold.
  # QA apps are listed too: a QA key is still not a development key.
  HEROKU_APPS = %w[
    mcritchie-studio turf-monster-mainnet mcritchie-industries
    rolio-prod tax-studio moms-app
    mcritchie-studio-qa turf-monster-qa mcritchie-industries-qa rolio-qa
  ].freeze

  # Where local env files live: the shared projects-root .env, each primary, and each desk.
  SCAN_GLOBS = [".env*", "*/.env*", "*/.worktrees/*/.env*"].freeze

  module_function

  # A fresh development key: 64 random bytes, hex, the shape `bin/rails secret` prints.
  def generate
    SecureRandom.hex(64)
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def prefix(hex_digest)
    hex_digest.to_s[0, PREFIX_LEN]
  end

  # The value the file sets, as dotenv would read it; nil when no line sets it.
  def read_value(path)
    return nil unless File.file?(path)

    File.foreach(path) do |line|
      m = LINE.match(line) or next
      return parse_value(m[2])
    end
    nil
  end

  # dotenv's reading of a raw right-hand side: a quoted value is its inner text;
  # an unquoted one ends at an inline ` #` comment.
  def parse_value(raw)
    raw = raw.to_s.strip
    if raw.length >= 2 && %w[" '].include?(raw[0]) && raw[-1] == raw[0]
      raw[1..-2]
    else
      raw.sub(/(\A|\s+)#.*\z/, "").strip
    end
  end

  # Set SECRET_KEY_BASE in `path` to a freshly generated development key. Every
  # line that sets it is rewritten to the one new value (so a duplicate line cannot
  # keep the old one alive); a file with no line gets one appended. The write is
  # atomic and keeps the file's permissions (0600 for a new file). Returns the new
  # value's digest, never the value.
  def rewrite(path, value: generate)
    lines = File.file?(path) ? File.readlines(path) : []
    replaced = false
    lines = lines.map do |line|
      m = LINE.match(line) or next line
      replaced = true
      "#{m[1]}#{value}#{m[3] || "\n"}"
    end
    unless replaced
      lines[-1] = "#{lines[-1]}\n" if lines.any? && !lines[-1].end_with?("\n")
      lines << "#{KEY}=#{value}\n"
    end
    atomic_write(path, lines.join)
    digest(value)
  end

  # Desk provisioning's hook: a COPIED env file that sets a non-empty key gets a
  # fresh one, so a desk can never inherit the value its primary holds, whatever it
  # is. A file with no key, or an empty one, is left alone (the app then falls back
  # to its own development secret). Returns the new digest, or nil when untouched.
  def replace_in_copy(path)
    value = read_value(path)
    return nil if value.nil? || value.empty?

    rewrite(path)
  end

  # Each env file under `projects_dir` (primaries and desks), sorted.
  def default_files(projects_dir)
    SCAN_GLOBS.flat_map { |glob| Dir.glob(File.join(projects_dir, glob), File::FNM_DOTMATCH) }
              .map { |path| File.expand_path(path) } # FNM_DOTMATCH lets `*` match `.`: ./.env
              .select { |path| File.file?(path) }
              .uniq.sort
  end

  # One row per file: {path:, state:, prefix:, app:}. state is
  #   :production  the value's digest is a known production digest (app: names it)
  #   :dev         a non-empty value that matches no production digest
  #   :empty       a line with no value (a template such as .env.example)
  #   :absent      no line sets the key
  # `production_digests` maps a full hex digest to the app that holds it.
  def scan(files, production_digests)
    files.map do |path|
      value = read_value(path)
      if value.nil?
        { path: path, state: :absent, prefix: nil, app: nil }
      elsif value.empty?
        { path: path, state: :empty, prefix: nil, app: nil }
      else
        d = digest(value)
        app = production_digests[d]
        { path: path, state: app ? :production : :dev, prefix: prefix(d), app: app }
      end
    end
  end

  # {full_digest => app} for each Heroku app whose config sets the key, plus
  # {unread: [apps]} for any app whose config could not be read. The value is
  # hashed inside this process and dropped; it is never returned or printed.
  # `runner` is a seam for tests: (app) -> [stdout, success?].
  def heroku_digests(apps = HEROKU_APPS, runner: method(:heroku_config_json))
    digests = {}
    unread = []
    apps.each do |app|
      out, ok = runner.call(app)
      config = ok ? (JSON.parse(out.to_s) rescue nil) : nil
      unless config.is_a?(Hash) && !config.empty?
        unread << app
        next
      end
      value = config[KEY].to_s
      digests[digest(value)] = app unless value.empty?
    end
    [digests, unread]
  end

  def heroku_config_json(app)
    out, _err, status = Open3.capture3("heroku", "config", "--json", "-a", app)
    [out, status.success?]
  rescue Errno::ENOENT
    ["", false]
  end

  def atomic_write(path, content)
    mode = File.exist?(path) ? (File.stat(path).mode & 0o777) : 0o600
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = Tempfile.create([".#{File.basename(path)}.", ".tmp"], dir)
    begin
      tmp.write(content)
      tmp.close
      File.chmod(mode, tmp.path)
      File.rename(tmp.path, path)
    ensure
      File.unlink(tmp.path) if File.exist?(tmp.path)
    end
  end
end
