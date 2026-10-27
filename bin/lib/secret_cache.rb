# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "projects_root"
require_relative "../../lib/task_usage_sandbox"

# SecretCache — the shared local cache for credentials that EXPIRE or ROTATE.
# Module doc: docs/agents/modules/secret-cache.md (registered as `secret-cache`).
#
# WHY (Alex McRitchie, 2026-10-27). 1Password's `op` hung from 06:14 to 08:17 MDT
# that morning and every ship waited on it. In the fourteen days before, about 77%
# of the 2,405 `op` reads were for one thing: the GitHub App credentials that mint a
# token which lives an hour. So 1Password becomes the FALLBACK: a credential with
# planned obsolescence is read from a deterministic local folder first, and `op` is
# read only on a miss, an expiry or a refresh, bounded, with a written contingency.
#
# WHERE. <projects>/.secret-cache (on this Mac /Users/alex/projects/.secret-cache),
# top-level and NOT inside .agents/, because local apps, desks and workflows on this
# Mac read it too. The directory is 0700 and every file 0600. Time Machine may back
# it up. It is never inside a git repository. A widened mode or a folder that has
# landed inside a repo FAILS LOUDLY (Unsafe), on read and on write.
#
# WHAT IS HERE, AND WHAT IS NOT. Cached secrets have planned obsolescence: GitHub
# App installation tokens (an hour), the machine's harness key (until revoked).
# Environment secrets (~/.zprofile, Heroku config) are meant to be stable and are
# NOT moved here. Production dynos cannot read this folder: it is a file on this Mac.
#
# THE RESOLUTION IS HOME-BASED (MCR_SECRET_CACHE_DIR, else CLAUDE_PROJECTS_DIR, else
# ~/projects), never __dir__-based, for the reason bin/gh-token#PROJECTS gives: an
# installed tooling snapshot lives at another path and must still reach the one
# shared folder.
#
# Ruby 2.6 syntax on purpose (no endless defs, no numbered params): bin/gh-token can
# load this under /usr/bin/ruby, like bin/lib/bounded_command.rb.
#
# NEVER A VALUE IN OUTPUT. Nothing here prints, logs or raises with a secret value.
# Status speaks in times; the manifest and README hold names and metadata only.
module SecretCache
  DIR_MODE = 0o700
  FILE_MODE = 0o600
  STORE = "secret-cache"
  MANIFEST = "manifest.json"
  README = "README.md"
  DIR_ENV = "MCR_SECRET_CACHE_DIR"

  GITHUB_FILE = "github-tokens.json"
  HARNESS_FILE = "harness-key.json"
  # GitHub App installation tokens live 3600 s; the last ten minutes are the
  # refresh window, so a read at 50 minutes mints and returns a fresh token.
  GITHUB_LIFETIME = 3600
  GITHUB_REFRESH_WINDOW = 600
  # A run that will hold a token for a long time (bin/release prepare/ship) starts
  # with one that has at least this much life left.
  LONG_RUN_MIN_LEFT = 45 * 60
  # Session start names any entry expired or expiring inside this horizon.
  SESSION_HORIZON = 3600

  # Raised when the folder is not safe to hold a credential: a widened mode, or a
  # location inside a git repository. Its message names the folder and the fix and
  # never a value.
  class Unsafe < StandardError; end

  CONTINGENCY = [
    "Use the other GitHub identity's cached token if it is still valid and its scope covers the job " \
    "(agent opens, reviews and merges PRs; deployer pushes main and deploys, and is never cached on disk).",
    "Run the token-session SOP (mcritchie-studio/docs/agents/modules/token-session.md).",
    "Ask Alex McRitchie to quit and reopen the 1Password app (that cleared the 2026-10-27 hang).",
    "Report it as a blocker: name the entry, the failing op read, and the steps tried."
  ].freeze

  GITHUB_COMMON = {
    "kind" => "github-app-token",
    "file" => GITHUB_FILE,
    "lifetime" => "60 minutes (GitHub App installation token)",
    "lifetime_seconds" => GITHUB_LIFETIME,
    "refresh_window" => "last 10 minutes: a read inside the window mints and returns a fresh token",
    "refresh_window_seconds" => GITHUB_REFRESH_WINDOW,
    "owner" => "steffon",
    "on_expired" => "bounded op read (about 20 s per attempt, bin/lib/op_meter.rb), mint, rewrite the cache",
    "contingency" => CONTINGENCY
  }.freeze

  # The default manifest entries. Names and metadata only: a value never appears
  # in the manifest. Long-lived 1Password items join only when named here (kind
  # "op-item"); none are by default — read bin/op-reads first, which now names the
  # item behind every bin/secret read.
  DEFAULT_ENTRIES = {
    "github.agent" => GITHUB_COMMON.merge(
      "identity" => "agent",
      "persist" => true,
      "source" => "1Password studio-agents/github.mcritchie-agent (app-id + private-key attachment)",
      "readers" => %w[bin/gh-token bin/gh-app-git-credential bin/lib/ci_status.rb bin/submit bin/pr-review
                      bin/dor-check bin/release]
    ),
    "github.deployer" => GITHUB_COMMON.merge(
      "identity" => "deployer",
      "persist" => false,
      "why_not_persisted" => "a build lane must not lift a deployer token off disk " \
                             "(bin/gh-token CACHEABLE_IDENTITIES); it is minted per call",
      "source" => "1Password studio-agents-admin/github.mcritchie-admin (app-id + private-key attachment)",
      "readers" => %w[bin/gh-token bin/gh-app-git-credential bin/release]
    ),
    "harness-key" => {
      "kind" => "harness-key",
      "file" => HARNESS_FILE,
      "lifetime" => "until revoked on the board",
      "refresh_window" => "none: the board answers a revoked key 401 and the tooling falls back to the shared token",
      "source" => "the board's grant (bin/harness-key request, then the Approve tap)",
      "owner" => "steffon",
      "readers" => %w[bin/lib/harness_key.rb bin/task bin/agent-activity bin/session-preflight],
      "on_expired" => "bin/harness-key request; until granted the tooling uses the shared agent token",
      "contingency" => [
        "The tooling already falls back to the shared agent token on a 401.",
        "Run bin/harness-key request and ask Alex McRitchie to approve it.",
        "Report it as a blocker if the shared token also fails."
      ]
    }
  }.freeze

  module_function

  # ── where ──────────────────────────────────────────────────────────────────

  # THE FOLDER, LAUNDERED. Every exported path to the folder goes through the
  # sandbox (lib/task_usage_sandbox.rb): an armed test run that is unpinned, or
  # pinned back at the operator's real folder, aborts here
  # (test/lib/state_store_containment_test.rb holds this file to that, LAYER 2a).
  def dir(env = ENV)
    TaskUsageSandbox.enforce!(location(env), store: STORE, env: TaskUsageSandbox.guard_env(env))
  end

  # The folder for a READ: nil, quietly, when a sandboxed run may not touch it, so
  # a read in a test answers "nothing cached" rather than reaching the real folder.
  def readable_dir(env = ENV)
    return nil if TaskUsageSandbox.violation(location(env), store: STORE, env: TaskUsageSandbox.guard_env(env))

    TaskUsageSandbox.enforce!(location(env), store: STORE, env: TaskUsageSandbox.guard_env(env))
  end

  # The raw resolution. Private: callers get #dir or #readable_dir.
  def location(env = ENV)
    override = env[DIR_ENV].to_s.strip
    return File.expand_path(override) unless override.empty?

    projects = env["CLAUDE_PROJECTS_DIR"].to_s.strip
    projects = File.expand_path("~/projects") if projects.empty?
    File.join(File.expand_path(projects), folder_name)
  end

  # ── safety ─────────────────────────────────────────────────────────────────

  # The directory (or a parent) that holds a `.git`, or nil. A cache inside a
  # repository is one `git add -A` away from a commit.
  def enclosing_repo(path)
    current = File.expand_path(path)
    loop do
      return current if File.exist?(File.join(current, ".git"))

      parent = File.dirname(current)
      return nil if parent == current

      current = parent
    end
  end

  def wider?(mode, allowed)
    (mode & 0o777 & ~allowed) != 0
  end

  # Fail loudly when the folder (if it exists) is unsafe. Cheap: a few stats.
  def check_safe!(env = ENV)
    home = readable_dir(env)
    return nil unless home

    repo = enclosing_repo(home)
    if repo
      raise Unsafe, "secret cache #{home} is inside the git repository at #{repo}; " \
                    "move it out (it belongs directly under the projects folder) — refusing to read or write it"
    end
    return home unless File.exist?(home)

    stat = File.lstat(home)
    raise Unsafe, "secret cache #{home} is a symlink; refusing it" if stat.symlink?

    mode = stat.mode & 0o777
    if wider?(mode, DIR_MODE)
      raise Unsafe, format("secret cache %s has mode %04o, wider than 0700; run `chmod 700 %s` " \
                           "and find what widened it", home, mode, home)
    end
    home
  end

  def check_file!(path)
    return path unless File.exist?(path)

    mode = File.stat(path).mode & 0o777
    if wider?(mode, FILE_MODE)
      raise Unsafe, format("secret cache file %s has mode %04o, wider than 0600; run `chmod 600 %s` " \
                           "and find what widened it", path, mode, path)
    end
    path
  end

  # Create the folder if needed, prove it safe, and lay down the README and the
  # manifest. Every write goes through here. Under TASK_USAGE_SANDBOX an unpinned
  # run aborts rather than reach the operator's real folder.
  def ensure_home!(env = ENV)
    home = dir(env)
    check_safe!(env)
    unless File.directory?(home)
      FileUtils.mkdir_p(File.dirname(home))
      begin
        Dir.mkdir(home, DIR_MODE)
      rescue Errno::EEXIST
        nil
      end
      File.chmod(DIR_MODE, home)
    end
    check_safe!(env)
    write_readme(home)
    ensure_manifest(home)
    home
  end

  # ── files ──────────────────────────────────────────────────────────────────

  # The parsed JSON in +file+, or nil when it is absent or corrupt. Raises Unsafe
  # on a widened folder or file: a credential in a world-readable file is not a
  # cache miss.
  def read_json(file, env: ENV)
    check_safe!(env)
    home = readable_dir(env)
    return nil unless home

    path = File.join(home, file)
    return nil unless File.file?(path)

    check_file!(path)
    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Write-then-rename, 0600 before the secret lands, so a reader never sees half a
  # file and no moment exists where the file is wider than 0600.
  def write_json(file, data, env: ENV)
    home = ensure_home!(env)
    atomic_write(File.join(home, file), "#{JSON.pretty_generate(data)}\n")
  end

  def delete(file, env: ENV)
    home = dir(env)
    path = File.join(home, file)
    File.delete(path) if File.exist?(path) || File.symlink?(path)
    true
  rescue Errno::ENOENT
    true
  end

  def file_exist?(file, env: ENV)
    home = readable_dir(env)
    !home.nil? && File.file?(File.join(home, file))
  end

  def atomic_write(path, content)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.open(tmp, File::CREAT | File::WRONLY | File::TRUNC, FILE_MODE) { |f| f.write(content) }
    File.chmod(FILE_MODE, tmp)
    File.rename(tmp, path)
    path
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  # ── legacy migration ───────────────────────────────────────────────────────

  # Move a legacy cache file into the folder and leave a symlink at the old path,
  # so a reader that still names the old path keeps working until every reader
  # has switched. The CALLER names and launders the legacy path (bin/gh-token,
  # bin/lib/harness_key.rb): this module never names <projects>/.agents.
  #
  # Idempotent. When the new file already exists and the legacy one is a regular
  # file (an older writer replaced the link by renaming over it), the legacy file
  # is re-pointed at the new one only when +relink+ is true — the caller has just
  # written the newer state.
  def adopt_legacy!(legacy_path, file, env: ENV, relink: false)
    return nil if legacy_path.to_s.empty?

    home = ensure_home!(env)
    target = File.join(home, file)
    legacy_is_file = File.file?(legacy_path) && !File.symlink?(legacy_path)
    if legacy_is_file && !File.exist?(target)
      atomic_write(target, File.read(legacy_path))
      relink = true
    end
    return target unless relink && legacy_is_file

    link_tmp = "#{legacy_path}.#{Process.pid}.link"
    File.delete(link_tmp) if File.symlink?(link_tmp)
    File.symlink(target, link_tmp)
    File.rename(link_tmp, legacy_path)
    target
  rescue SystemCallError
    target
  end

  # ── manifest ───────────────────────────────────────────────────────────────

  def manifest(env = ENV)
    data = read_json(MANIFEST, env: env) || {}
    entries = data["entries"].is_a?(Hash) ? data["entries"] : {}
    merged = {}
    DEFAULT_ENTRIES.each { |name, meta| merged[name] = meta.merge(entries[name].is_a?(Hash) ? entries[name] : {}) }
    entries.each { |name, meta| merged[name] ||= meta if meta.is_a?(Hash) }
    merged
  rescue Unsafe
    raise
  rescue StandardError
    DEFAULT_ENTRIES.dup
  end

  def entry(name, env = ENV)
    manifest(env)[name.to_s]
  end

  # Keep the operator's edits; add any default entry the file lacks.
  def ensure_manifest(home)
    path = File.join(home, MANIFEST)
    data = begin
      File.file?(path) ? JSON.parse(File.read(path)) : {}
    rescue JSON::ParserError
      {}
    end
    data = {} unless data.is_a?(Hash)
    entries = data["entries"].is_a?(Hash) ? data["entries"] : {}
    changed = !File.file?(path)
    DEFAULT_ENTRIES.each do |name, meta|
      next if entries[name].is_a?(Hash)

      entries[name] = meta
      changed = true
    end
    return path unless changed

    data["about"] = "Names and metadata only, never a value. Rules: README.md here; " \
                    "doc: mcritchie-studio/docs/agents/modules/secret-cache.md"
    data["entries"] = entries
    atomic_write(path, "#{JSON.pretty_generate(data)}\n")
  end

  # Stamp expires_at on mint (and clear a recorded failure), or record a failed
  # refresh. Best-effort: bookkeeping never fails the read it describes.
  def record_mint!(name, expires_at, env: ENV)
    update_entry!(name, env) do |meta|
      meta["expires_at"] = expires_at.utc.iso8601
      meta.delete("last_refresh_failed_at")
    end
  end

  def record_failure!(name, env: ENV, now: Time.now)
    update_entry!(name, env) { |meta| meta["last_refresh_failed_at"] = now.utc.iso8601 }
  end

  def update_entry!(name, env)
    # Bookkeeping never aborts its caller: a sandboxed run that may not touch the
    # folder records nothing, quietly (the read or mint it describes goes on).
    return false unless readable_dir(env)

    home = ensure_home!(env)
    path = File.join(home, MANIFEST)
    data = JSON.parse(File.read(path))
    data["entries"] ||= {}
    meta = data["entries"][name.to_s].is_a?(Hash) ? data["entries"][name.to_s] : {}
    yield meta
    data["entries"][name.to_s] = meta
    atomic_write(path, "#{JSON.pretty_generate(data)}\n")
    true
  rescue StandardError
    false
  end

  # ── GitHub slots (the format bin/gh-token writes) ─────────────────────────

  def time_or_nil(value)
    value.to_s.strip.empty? ? nil : Time.parse(value.to_s).utc
  rescue ArgumentError
    nil
  end

  # When a slot's token expires: its recorded expires_at, else created_at + an hour.
  def slot_expires_at(slot)
    return nil unless slot.is_a?(Hash) && !slot["token"].to_s.strip.empty?

    time_or_nil(slot["expires_at"]) || begin
      created = time_or_nil(slot["created_at"])
      created && created + GITHUB_LIFETIME
    end
  end

  # The latest expiry among an identity's slots across +stores+, or nil.
  def github_expires_at(identity, stores)
    Array(stores).map { |store| store.is_a?(Hash) ? store[identity.to_s] : nil }
                 .select { |e| e.is_a?(Hash) }
                 .flat_map { |e| %w[a b].map { |k| slot_expires_at(e[k]) } }
                 .compact.max
  end

  # ── values for op-item entries (none by default) ──────────────────────────

  def value_file(name)
    "item.#{name.to_s.gsub(/[^A-Za-z0-9._-]/, '_')}.json"
  end

  # The manifest entry naming this 1Password reference, or nil.
  def item_entry(vault, item, field, env = ENV)
    manifest(env).find do |_name, meta|
      meta["kind"] == "op-item" && meta["vault"] == vault && meta["item"] == item &&
        (meta["field"] || "password") == field
    end
  end

  # [value, expires_at] for an op-item entry when still outside its refresh window.
  def cached_item(name, env: ENV, now: Time.now)
    meta = entry(name, env) || {}
    data = read_json(value_file(name), env: env)
    return nil unless data && !data["value"].to_s.empty?

    expires = time_or_nil(data["expires_at"])
    return nil if expires.nil?
    return nil if now >= expires - meta["refresh_window_seconds"].to_i

    data["value"]
  end

  def store_item(name, value, env: ENV, now: Time.now)
    meta = entry(name, env) || {}
    lifetime = meta["lifetime_seconds"].to_i
    lifetime = 86_400 unless lifetime.positive?
    expires = now + lifetime
    write_json(value_file(name), { "value" => value, "fetched_at" => now.utc.iso8601,
                                   "expires_at" => expires.utc.iso8601 }, env: env)
    record_mint!(name, expires, env: env)
  end

  # ── status ─────────────────────────────────────────────────────────────────

  # "42 min", "1 h 5 min", "under a minute".
  def duration_words(seconds)
    seconds = seconds.to_i.abs
    return "under a minute" if seconds < 60

    minutes = seconds / 60
    return "#{minutes} min" if minutes < 60

    hours = minutes / 60
    rest = minutes % 60
    rest.zero? ? "#{hours} h" : "#{hours} h #{rest} min"
  end

  # One entry's state as a hash: :state (:fresh, :window, :expired, :absent,
  # :not_persisted, :held), :expires_at, and a :words sentence. No value.
  def entry_state(name, meta, env: ENV, now: Time.now)
    case meta["kind"]
    when "github-app-token"
      return { state: :not_persisted, words: "not cached by design: minted per call" } if meta["persist"] == false

      expires = github_expires_at(meta["identity"], [read_json(GITHUB_FILE, env: env)])
      timed_state(expires, meta["refresh_window_seconds"] || GITHUB_REFRESH_WINDOW, now)
    when "harness-key"
      data = read_json(HARNESS_FILE, env: env)
      if data && !data["token"].to_s.strip.empty?
        { state: :held, words: "held: no expiry, revoked on the board" }
      else
        { state: :absent, words: "absent: the tooling uses the shared agent token" }
      end
    when "op-item"
      data = read_json(value_file(name), env: env)
      timed_state(data && time_or_nil(data["expires_at"]), meta["refresh_window_seconds"].to_i, now)
    else
      { state: :absent, words: "unknown kind #{meta['kind'].inspect}" }
    end
  end

  def timed_state(expires, window, now)
    return { state: :absent, words: "not cached: the next read fetches it" } if expires.nil?

    left = expires - now
    if left <= 0
      { state: :expired, expires_at: expires, words: "expired #{duration_words(left)} ago — refreshes on next read" }
    elsif left <= window.to_i
      { state: :window, expires_at: expires,
        words: "expires in #{duration_words(left)} — inside the refresh window, the next read refreshes" }
    else
      { state: :fresh, expires_at: expires, words: "expires in #{duration_words(left)}" }
    end
  end

  def status_lines(env: ENV, now: Time.now)
    lines = ["secret cache: #{dir(env)}"]
    manifest(env).each do |name, meta|
      state = entry_state(name, meta, env: env, now: now)
      line = "  #{name}: #{state[:words]}"
      failed = time_or_nil(meta["last_refresh_failed_at"])
      line += " (last refresh FAILED #{duration_words(now - failed)} ago)" if failed
      lines << line
    end
    lines
  end

  # The SessionStart block: every entry expired or expiring within the hour, or ""
  # when nothing is due. Never raises and never spawns a process.
  def session_block(env: ENV, now: Time.now, horizon: SESSION_HORIZON)
    home = readable_dir(env)
    return "" unless home && File.directory?(home)

    due = manifest(env).map do |name, meta|
      state = entry_state(name, meta, env: env, now: now)
      failed = time_or_nil(meta["last_refresh_failed_at"])
      soon = state[:expires_at] && state[:expires_at] - now <= horizon
      next unless soon || failed

      words = state[:words]
      words += "; it refreshes itself on read" if meta["kind"] == "github-app-token" && !failed
      words += "; the LAST REFRESH FAILED — run bin/secret status and follow the contingency" if failed
      "- #{name}: #{words}"
    end.compact
    return "" if due.empty?

    "## Secret cache (#{home})\n#{due.join("\n")}"
  rescue Unsafe => e
    "## Secret cache\n- UNSAFE: #{e.message}"
  rescue StandardError
    ""
  end

  # The contingency ladder for +name+, step 1 annotated with the live state of the
  # other GitHub identity. Lines only; never a value.
  def contingency_lines(name, env: ENV, now: Time.now)
    meta = entry(name, env) || {}
    steps = Array(meta["contingency"]).empty? ? CONTINGENCY : Array(meta["contingency"])
    other = { "github.agent" => "github.deployer", "github.deployer" => "github.agent" }[name.to_s]
    lines = ["contingency for #{name} (in order):"]
    steps.each_with_index do |step, i|
      line = "  #{i + 1}. #{step}"
      if i.zero? && other
        other_meta = entry(other, env) || {}
        state = begin
          entry_state(other, other_meta, env: env, now: now)[:words]
        rescue StandardError
          "unreadable"
        end
        line += " Now: #{other} is #{state}."
      end
      lines << line
    end
    lines
  end

  # ── README ─────────────────────────────────────────────────────────────────

  def readme_text(home)
    <<~MD
      # Secret cache — #{home}

      Written by the tooling (bin/lib/secret_cache.rb). Do not edit; it is rewritten.
      Full doc: mcritchie-studio/docs/agents/modules/secret-cache.md (SOP name `secret-cache`).

      ## Rules

      - This folder holds credentials that EXPIRE or ROTATE, read here first and from
        1Password only on a miss, an expiry, or a read inside the refresh window.
      - Folder 0700, files 0600. The tooling refuses to read or write it if either is
        wider, or if the folder is inside a git repository. Never commit it, never copy
        a file out of it, never `cat` a file in it.
      - Read through `bin/secret` (status, get, refresh, forget) or bin/gh-token, never
        by opening the files. `bin/secret status` shows time left and never a value.
      - Environment secrets (~/.zprofile, Heroku config) are stable and do NOT live here.
      - Production dynos cannot read this folder; it exists only on this Mac.
      - A rotated key: run `bin/secret forget <name>` (credential-rotation SOP) so the
        old value never lingers here.

      ## Manifest

      `#{MANIFEST}` names every entry with its lifetime, refresh window, source,
      owner, readers, on-expiry action and contingency. Names and metadata only.
    MD
  end

  # The folder's name. Private, like every raw builder here (LAYER 2a).
  def folder_name
    ".secret-cache"
  end

  private_class_method :location
  private_class_method :folder_name

  def write_readme(home)
    path = File.join(home, README)
    text = readme_text(home)
    return path if File.file?(path) && File.read(path) == text

    atomic_write(path, text)
  rescue SystemCallError
    path
  end
end
