# frozen_string_literal: true

require "find"
require "json"
require "open3"
require "fileutils"
require "tempfile"
require "time"

# AgentsBackup — the nightly ENCRYPTED backup of this Mac's agent state that no
# git repository holds: /Users/alex/projects/.agents and Claude Code's memory
# folder (task safety-floor-settings, 2026-11-06; 11-02 system audit finding 8).
#
# Shape. Ruby picks the files (`plan`): regular files only, symlinks never
# followed, and every token or secret file excluded by name (EXCLUDE_*). rclone
# then copies exactly that list, `--files-from`, through an rclone `crypt`
# remote (file contents AND names encrypted, key in 1Password) into the private
# R2 bucket `mcritchie-agents-backup`:
#
#   current/<source>/<path>        the latest copy of every file ever backed up
#   archive/<stamp>/<source>/...   the old copy of each file a run overwrote
#
# `copy`, never `sync`: a file deleted on the Mac stays in current/, so a wiped
# folder cannot wipe its backup. The archive keeps ARCHIVE_DAYS of overwrites;
# `run` collects older stamps after a successful copy. Paths in the bucket are
# encrypted names, so the bucket listing reveals nothing but sizes.
#
# Credentials: item r2.mcritchie-agents-backup in the agent vault (fields
# access-key-id, secret-access-key, endpoint, crypt-password, crypt-salt), read
# by the CLI and handed to rclone in the child's environment only. Nothing here
# prints a value.
module AgentsBackup
  BUCKET = "mcritchie-agents-backup"
  ITEM = "r2.#{BUCKET}"
  ARCHIVE_DAYS = 30
  STAMP_FORMAT = "%Y%m%dT%H%M%SZ"
  STAMP_RE = /\A\d{8}T\d{6}Z\z/

  # The two sources. Their default roots live in bin/agents-backup
  # (default_sources), not here: a shared lib may export no path into the
  # agent store (test/lib/state_store_containment_test.rb, LAYER 2a).
  SOURCE_NAMES = %w[agents memory].freeze

  # Directories never entered. .secret-* covers the secret cache (live tokens),
  # should one ever be nested here; tooling/ and bin.pre-tooling-* are copies of
  # shipped hub code; locks/ is runtime state.
  EXCLUDE_DIRS = [".git", "node_modules", "tooling", "locks"].freeze
  EXCLUDE_DIR_GLOBS = [".secret-*", "bin.pre-tooling-*"].freeze

  # Files never copied, matched on the basename (File.fnmatch, case-insensitive,
  # dotfiles included). A note ABOUT tokens (memory/hub-entry-tokens.md) is not
  # a token file and is kept.
  EXCLUDE_FILE_GLOBS = [
    "*.token", "token.json", "*-token.json", "*tokens.json", "*tokens.json.lock",
    ".env", ".env*", "*.env",
    "*.pem", "*.key", "*.p12", "*.pfx", "id_rsa*", "id_ed25519*",
    "harness-key.json", "*-key.json", "keys.txt", "*credentials*.json", "*secret*.json",
    "*.lock",
    # The op read log names every 1Password item and field read on this Mac: a
    # map of the credentials, worthless to restore.
    "op-reads.log*",
    # The admin-login session marker holds a live board bearer token
    # (bin/lib/admin_login.rb).
    "*.admin-login"
  ].freeze

  FNM = File::FNM_CASEFOLD | File::FNM_DOTMATCH

  module_function

  def excluded_dir?(name)
    EXCLUDE_DIRS.include?(name) || EXCLUDE_DIR_GLOBS.any? { |g| File.fnmatch?(g, name, FNM) }
  end

  def excluded_file?(name) = EXCLUDE_FILE_GLOBS.any? { |g| File.fnmatch?(g, name, FNM) }

  # +defaults+ is source name => root; AGENTS_BACKUP_<NAME>_DIR overrides a root.
  def sources(defaults, env = ENV)
    SOURCE_NAMES.to_h { |name| [name, env.fetch("AGENTS_BACKUP_#{name.upcase}_DIR", defaults.fetch(name))] }
  end

  # The relative paths under +root+ a run copies, sorted. Symlinks (to files or
  # folders) are skipped, not followed: .agents/github-tokens.json is a symlink
  # into .secret-cache.
  def plan(root)
    return [] unless File.directory?(root)

    files = []
    Find.find(root) do |path|
      next if path == root

      name = File.basename(path)
      if File.symlink?(path)
        Find.prune if File.directory?(path)
        next
      end
      if File.directory?(path)
        Find.prune if excluded_dir?(name)
        next
      end
      next unless File.file?(path)
      next if excluded_file?(name)

      files << path.delete_prefix("#{root}/")
    end
    files.sort
  end

  def stamp(now = Time.now.utc) = now.utc.strftime(STAMP_FORMAT)

  # Archive stamps older than +days+ before +now+; anything not stamp-shaped is
  # never returned, so collection can only ever delete a stamp folder.
  def expired_stamps(names, now:, days: ARCHIVE_DAYS)
    cutoff = now - (days * 86_400)
    names.map { |n| n.to_s.strip.delete_suffix("/") }.select do |n|
      n.match?(STAMP_RE) && Time.strptime("#{n}+0000", "#{STAMP_FORMAT}%z") < cutoff
    end.sort
  end

  # rclone's environment: an S3 remote `ab_r2` on R2 and a crypt remote
  # `ab_crypt` over the bucket. +creds+ holds the 1Password fields; the crypt
  # passwords must already be in rclone's obscured form.
  def rclone_env(creds)
    {
      "RCLONE_CONFIG_AB_R2_TYPE" => "s3",
      "RCLONE_CONFIG_AB_R2_PROVIDER" => "Cloudflare",
      "RCLONE_CONFIG_AB_R2_NO_CHECK_BUCKET" => "true",
      "RCLONE_CONFIG_AB_R2_ENDPOINT" => creds.fetch("endpoint"),
      "RCLONE_CONFIG_AB_R2_ACCESS_KEY_ID" => creds.fetch("access-key-id"),
      "RCLONE_CONFIG_AB_R2_SECRET_ACCESS_KEY" => creds.fetch("secret-access-key"),
      "RCLONE_CONFIG_AB_CRYPT_TYPE" => "crypt",
      "RCLONE_CONFIG_AB_CRYPT_REMOTE" => "ab_r2:#{BUCKET}",
      "RCLONE_CONFIG_AB_CRYPT_FILENAME_ENCRYPTION" => "standard",
      "RCLONE_CONFIG_AB_CRYPT_DIRECTORY_NAME_ENCRYPTION" => "true",
      "RCLONE_CONFIG_AB_CRYPT_PASSWORD" => creds.fetch("crypt-password-obscured"),
      "RCLONE_CONFIG_AB_CRYPT_PASSWORD2" => creds.fetch("crypt-salt-obscured")
    }
  end

  # Drives rclone. +shell+ is (argv, env) -> [output, exitstatus]; tests pass a fake.
  class Runner
    attr_reader :log

    def initialize(env:, sources:, shell: nil, out: $stdout)
      @env = env
      @shell = shell || method(:system_shell)
      @sources = sources
      @out = out
    end

    # Copy every planned file of every source; then collect expired archive
    # stamps, only when every copy succeeded. Returns a receipt hash.
    def run(now: Time.now.utc, dry_run: false)
      stamp = AgentsBackup.stamp(now)
      receipt = { "stamp" => stamp, "bucket" => BUCKET, "dry_run" => dry_run, "sources" => {}, "collected" => [] }
      @sources.each do |name, root|
        files = AgentsBackup.plan(root)
        rc = files.empty? ? 0 : copy(root, name, files, stamp, dry_run: dry_run)
        receipt["sources"][name] = { "root" => root, "files" => files.length, "rclone_exit" => rc }
      end
      receipt["ok"] = receipt["sources"].values.all? { |s| s["rclone_exit"].zero? && s["files"].positive? }
      receipt["collected"] = collect(now: now, dry_run: dry_run) if receipt["ok"]
      receipt
    end

    # Restore one file of +source+ from current/ into +dest_dir+ (never in place).
    def restore(source, rel, dest_dir)
      raise ArgumentError, "unknown source #{source}" unless @sources.key?(source)
      raise ArgumentError, "path must be relative and inside the source" if rel.start_with?("/") || rel.split("/").include?("..")

      FileUtils.mkdir_p(dest_dir)
      target = File.join(dest_dir, File.basename(rel))
      _, rc = rclone("copyto", "ab_crypt:current/#{source}/#{rel}", target)
      [target, rc]
    end

    def collect(now:, dry_run:)
      out, rc = rclone("lsf", "--dirs-only", "ab_crypt:archive/")
      return [] unless rc.zero?

      AgentsBackup.expired_stamps(out.lines, now: now).each do |s|
        rclone("purge", "ab_crypt:archive/#{s}") unless dry_run
      end
    end

    private

    def copy(root, name, files, stamp, dry_run:)
      Tempfile.create(["agents-backup-#{name}", ".txt"]) do |list|
        list.write(files.join("\n"))
        list.write("\n")
        list.flush
        args = ["copy", root, "ab_crypt:current/#{name}", "--files-from-raw", list.path,
                "--backup-dir", "ab_crypt:archive/#{stamp}/#{name}",
                "--transfers", "8", "--stats-one-line", "--stats", "0", "-q"]
        args << "--dry-run" if dry_run
        _, rc = rclone(*args)
        rc
      end
    end

    def rclone(*args) = @shell.call(["rclone", *args], @env)

    # stdout only: rclone's log lines (stderr) go to the caller's stderr, the
    # launchd log at night, and never into a listing the runner parses.
    def system_shell(argv, env)
      out, status = Open3.capture2(env, *argv)
      [out, status.exitstatus || 1]
    end
  end
end
