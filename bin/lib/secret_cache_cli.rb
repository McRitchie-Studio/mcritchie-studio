# frozen_string_literal: true

# The Ruby half of bin/secret: every subcommand that is not the classic
# `bin/secret <vault> <item> [field]` read. Doc: docs/agents/modules/secret-cache.md.
#
#   bin/secret status                       each entry's time left; never a value
#   bin/secret get <name>                   the value, on stdout only (cache, else a bounded op read)
#   bin/secret refresh <name> [--if-under <minutes>]   mint now (or only when less life is left)
#   bin/secret forget <name>                drop one entry; the next read fetches it fresh
#   bin/secret forget --source <1Password item>       drop every entry fed by that item (rotation)
#   bin/secret contingency <name>           the ordered steps when 1Password fails or hangs
#   bin/secret migrate                      move the legacy .agents caches in (idempotent)
#   bin/secret prewarm                      before a long run: refresh tokens with under 45 min left
#
# A VALUE IS PRINTED BY `get` (and the classic read) ONLY, to stdout, so
# `X="$(bin/secret get github.agent)"` works. Every other line is metadata.

require "json"
require "open3"
require "tempfile"
require_relative "secret_cache"
require_relative "op_meter"

module SecretCacheCli
  USAGE = <<~TXT
    usage: bin/secret status
           bin/secret get <name>
           bin/secret refresh <name> [--if-under <minutes>]
           bin/secret forget <name> | --source <1Password item>
           bin/secret contingency <name>
           bin/secret migrate
           bin/secret prewarm
           bin/secret <vault> <item> [field]      (the classic 1Password read)
  TXT

  NOT_MANAGED = 3

  module_function

  def bin_dir
    File.expand_path("..", __dir__)
  end

  def gh_token_bin(env = ENV)
    override = env["SECRET_GH_TOKEN_BIN"].to_s.strip
    override.empty? ? File.join(bin_dir, "gh-token") : override
  end

  def op_bin(env = ENV)
    override = env["SECRET_OP_BIN"].to_s.strip
    override.empty? ? "/opt/homebrew/bin/op" : override
  end

  def run(argv, env: ENV, out: $stdout, err: $stderr)
    command = argv.shift
    case command
    when "status" then status(env, out)
    when "get" then get(argv.shift.to_s, env, out, err)
    when "refresh" then refresh(argv, env, out, err)
    when "forget" then forget(argv, env, out, err)
    when "contingency"
      out.puts(SecretCache.contingency_lines(argv.shift.to_s, env: env))
      0
    when "migrate" then migrate(env, out, err)
    when "prewarm" then prewarm(env, out, err)
    when "read-item" then read_item(argv, env, out, err)
    when "help", "-h", "--help"
      out.puts(USAGE)
      0
    else
      err.puts(USAGE)
      2
    end
  rescue SecretCache::Unsafe => e
    err.puts("secret: #{e.message}")
    1
  end

  def known!(name, env, err)
    meta = SecretCache.entry(name, env)
    return meta if meta

    err.puts("secret: no entry named #{name.inspect} in the manifest (bin/secret status lists them)")
    nil
  end

  # ── status ─────────────────────────────────────────────────────────────────

  def status(env, out)
    SecretCache.check_safe!(env)
    now = Time.now
    out.puts("secret cache: #{SecretCache.dir(env)}#{File.directory?(SecretCache.dir(env)) ? '' : ' (not created yet)'}")
    SecretCache.manifest(env).each do |name, meta|
      state = if meta["kind"] == "github-app-token" && meta["persist"] != false
                SecretCache.timed_state(github_expires_at(meta["identity"], env),
                                        meta["refresh_window_seconds"] || SecretCache::GITHUB_REFRESH_WINDOW, now)
              else
                SecretCache.entry_state(name, meta, env: env, now: now)
              end
      line = "  #{name}: #{state[:words]}"
      failed = SecretCache.time_or_nil(meta["last_refresh_failed_at"])
      line += " (last refresh FAILED #{SecretCache.duration_words(now - failed)} ago)" if failed
      out.puts(line)
    end
    0
  end

  # What bin/gh-token says about the token a read would return (it reads the
  # legacy file too). Never a token: --expires-at prints a time or nothing.
  def github_expires_at(identity, env)
    stdout, _err, status = Open3.capture3(env.to_h, gh_token_bin(env), "--identity", identity.to_s, "--expires-at")
    return nil unless status.success?

    SecretCache.time_or_nil(stdout.strip)
  rescue SystemCallError
    nil
  end

  # ── get / refresh / forget ─────────────────────────────────────────────────

  def get(name, env, out, err)
    meta = known!(name, env, err) or return 1
    case meta["kind"]
    when "github-app-token"
      stdout, status = gh_token(env, err, "--identity", meta["identity"])
      out.print(stdout) if status
      status ? 0 : 1
    when "op-item"
      value = item_value(name, meta, env, err)
      return 1 unless value

      out.print(value)
      0
    else
      err.puts("secret: #{name} is read by its own tooling and is never printed (#{meta['readers']&.first})")
      1
    end
  end

  def refresh(argv, env, out, err)
    name = argv.shift.to_s
    under = nil
    while (arg = argv.shift)
      if arg == "--if-under"
        under = Float(argv.shift.to_s, exception: false)
        return usage_error(err, "--if-under takes minutes") unless under
      else
        return usage_error(err, "unexpected #{arg.inspect}")
      end
    end
    meta = known!(name, env, err) or return 1
    unless meta["kind"] == "github-app-token" && meta["persist"] != false
      if meta["kind"] == "op-item"
        SecretCache.delete(SecretCache.value_file(name), env: env)
        return item_value(name, meta, env, err) ? report(out, name, "refreshed") : 1
      end
      err.puts("secret: #{name} has nothing to refresh (#{meta['lifetime']})")
      return 1
    end

    if under
      expires = github_expires_at(meta["identity"], env)
      if expires && expires - Time.now >= under * 60
        out.puts("#{name}: fresh enough — expires in #{SecretCache.duration_words(expires - Time.now)}")
        return 0
      end
    end
    _stdout, ok = gh_token(env, err, "--identity", meta["identity"], "--force")
    return 1 unless ok

    expires = github_expires_at(meta["identity"], env)
    report(out, name, expires ? "refreshed — expires in #{SecretCache.duration_words(expires - Time.now)}" : "refreshed")
  end

  def forget(argv, env, out, err)
    names = if argv.first == "--source"
              item = argv[1].to_s
              return usage_error(err, "--source takes a 1Password item name") if item.empty?

              SecretCache.manifest(env).select { |_n, m| m["source"].to_s.include?(item) || m["item"] == item }.keys
            else
              [argv.first.to_s]
            end
    if names.empty?
      out.puts("secret: no manifest entry is fed by #{argv[1]}; nothing to forget")
      return 0
    end

    names.each do |name|
      meta = known!(name, env, err) or return 1
      case meta["kind"]
      when "github-app-token"
        _stdout, ok = gh_token(env, err, "--identity", meta["identity"], "--forget")
        return 1 unless ok
      when "harness-key"
        require_relative "harness_key"
        HarnessKey.clear(File.dirname(SecretCache.dir(env)), env: env)
      else
        SecretCache.delete(SecretCache.value_file(name), env: env)
      end
      SecretCache.update_entry!(name, env) do |m|
        m.delete("expires_at")
        m.delete("last_refresh_failed_at")
      end
      report(out, name, "forgotten — the next read fetches it fresh")
    end
    0
  end

  def migrate(env, out, err)
    SecretCache.ensure_home!(env)
    _stdout, ok = gh_token(env, err, "--migrate")
    require_relative "harness_key"
    projects = File.dirname(SecretCache.dir(env))
    HarnessKey.migrate!(projects, env: env)
    out.puts("secret cache: #{SecretCache.dir(env)} — legacy caches adopted#{ok ? '' : ' (gh-token: see above)'}")
    ok ? 0 : 1
  end

  # Before bin/release prepare/ship: a token with less than LONG_RUN_MIN_LEFT left
  # is minted fresh now, so it cannot expire mid-run. Never fatal.
  def prewarm(env, out, err)
    minutes = SecretCache::LONG_RUN_MIN_LEFT / 60
    SecretCache.manifest(env).each do |name, meta|
      next unless meta["kind"] == "github-app-token" && meta["persist"] != false

      refresh([name, "--if-under", minutes.to_s], env, out, err)
    end
    0
  rescue StandardError => e
    err.puts("secret: prewarm skipped (#{e.class})")
    0
  end

  # ── the classic read, for an op-item entry ────────────────────────────────

  # Exit NOT_MANAGED when no manifest entry names this reference: bin/secret then
  # does its classic read.
  def read_item(argv, env, out, err)
    vault, item, field = argv
    found = SecretCache.item_entry(vault.to_s, item.to_s, (field || "password").to_s, env)
    return NOT_MANAGED unless found

    value = item_value(found.first, found.last, env, err)
    return 1 unless value

    out.print(value)
    0
  end

  def item_value(name, meta, env, err)
    cached = SecretCache.cached_item(name, env: env)
    return cached if cached

    ref = "op://#{meta['vault']}/#{meta['item']}/#{meta['field'] || 'password'}"
    value = Tempfile.create("secret-op-err") do |errfile|
      read = OpMeter.popen({}, [op_bin(env), "read", ref], via: "secret:#{meta['vault']}/#{meta['item']}", err: errfile)
      $?.success? ? read.to_s.chomp : ""
    end
    if value.empty?
      SecretCache.record_failure!(name, env: env)
      err.puts("secret: could not read #{ref}")
      err.puts(SecretCache.contingency_lines(name, env: env))
      return nil
    end
    SecretCache.store_item(name, value, env: env)
    value
  rescue SystemCallError
    err.puts("secret: 1Password CLI not found at #{op_bin(env)}")
    nil
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Run bin/gh-token; its stderr passes through, its stdout (a token, for a bare
  # read) is returned to the caller and never printed here.
  def gh_token(env, err, *args)
    stdout, stderr, status = Open3.capture3(env.to_h, gh_token_bin(env), *args)
    err.print(stderr) unless stderr.empty?
    [stdout, status.success?]
  rescue SystemCallError => e
    err.puts("secret: cannot run bin/gh-token (#{e.class})")
    ["", false]
  end

  def report(out, name, words)
    out.puts("#{name}: #{words}")
    0
  end

  def usage_error(err, message)
    err.puts("secret: #{message}")
    err.puts(USAGE)
    2
  end
end

exit(SecretCacheCli.run(ARGV.dup)) if $PROGRAM_NAME == __FILE__
