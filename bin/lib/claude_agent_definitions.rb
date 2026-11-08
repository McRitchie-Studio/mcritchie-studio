# frozen_string_literal: true

require "fileutils"
require "open3"

# The Claude Code subagent definitions (~/.claude/agents/<soul>.md) and their one
# source each in the hub: docs/agents/agents/<soul>/claude-agent.md.
#
# WHY THIS EXISTS (task agent-definitions-from-repo). The installed definitions feed
# the Agent tool listing in every session, and no installer wrote them: they were
# copied by hand, so 5 of 9 had no source in any repo, 3 differed from their repo
# copy, and some cited files that no longer exist (refactor review 2026-11-06,
# lane-docs). This module is the one code path for writing them and for telling
# when an installed copy differs from its source.
#
# THE HOME. The soul folder already held four sources (alex, mack, mason, pokemon),
# each soul's role.md already names its claude-agent.md, and the soul's own docs
# sit beside it. So every soul's definition lives in its folder; there is no second
# "claude-agents" tree to keep in step.
#
# WHAT IT NEVER DOES. It writes only <dest>/<soul>.md for a soul that has a source.
# A file in <dest> with no source (a hand-made agent, an old *.bak) is reported and
# left alone. Before it overwrites a file whose bytes differ, it copies that file to
# a backup folder OUTSIDE <dest> (Claude Code loads every *.md under the agents
# folder, so a backup inside it would load as a duplicate agent).
module ClaudeAgentDefinitions
  SOURCE_GLOB = "docs/agents/agents/*/claude-agent.md"
  SOURCE_RE = %r{\Adocs/agents/agents/([^/]+)/claude-agent\.md\z}

  Source = Struct.new(:name, :rel, :content, keyword_init: true)
  Result = Struct.new(:name, :target, :status, :backup, keyword_init: true)

  class SourceError < StandardError; end

  module_function

  # The default install target, beside the user-global skills install.
  def default_dest(home = Dir.home)
    File.join(home, ".claude", "agents")
  end

  # Backups go beside the agents folder, never inside it.
  def default_backup_root(dest)
    File.join(File.dirname(File.expand_path(dest)), "agents-backup")
  end

  # Every source, from the working tree at `root`, or from commit `rev` of the
  # repo at `root` when given (the check compares with the tree the last ship
  # published). Sorted by name. Raises SourceError when a source's frontmatter
  # `name:` is not its folder's name: Claude Code names the agent from that line,
  # so a mismatch would install one soul's file under another soul's name.
  def sources(root, rev: nil)
    rels = rev ? git_ls(root, rev) : Dir.glob(File.join(root, SOURCE_GLOB)).map { |p| p.delete_prefix("#{root}/") }
    rels.filter_map do |rel|
      soul = rel[SOURCE_RE, 1] or next
      content = rev ? git_show(root, rev, rel) : File.binread(File.join(root, rel))
      declared = frontmatter_name(content)
      unless declared == soul
        raise SourceError, "#{rel}: frontmatter name is #{declared.inspect}, expected #{soul.inspect}"
      end
      Source.new(name: soul, rel: rel, content: content)
    end.sort_by(&:name)
  end

  def frontmatter_name(content)
    head = content[/\A---\n(.*?)\n---\n/m, 1] or return nil
    head[/^name:\s*(\S+)\s*$/, 1]
  end

  # One status per source: :create (no target), :same, or :differs.
  def compare(sources, dest)
    sources.map do |src|
      target = File.join(dest, "#{src.name}.md")
      status =
        if !File.file?(target) then :create
        elsif File.binread(target) == src.content then :same
        else :differs
        end
      Result.new(name: src.name, target: target, status: status)
    end
  end

  # Installed *.md files that no source names. Reported, never touched.
  def unmanaged(sources, dest)
    names = sources.map(&:name)
    Dir.glob(File.join(dest, "*.md")).map { |p| File.basename(p, ".md") }.reject { |n| names.include?(n) }.sort
  end

  # Write every source into `dest`. A target whose bytes differ is first copied to
  # <backup_root>/<stamp>/<soul>.md. Returns one Result per source, with status
  # :created, :unchanged or :updated.
  def install!(sources, dest, backup_root: default_backup_root(dest), now: Time.now)
    FileUtils.mkdir_p(dest)
    stamp = now.utc.strftime("%Y%m%dT%H%M%SZ")
    compare(sources, dest).zip(sources).map do |res, src|
      case res.status
      when :same
        Result.new(name: res.name, target: res.target, status: :unchanged)
      when :create
        write_atomic(res.target, src.content)
        Result.new(name: res.name, target: res.target, status: :created)
      when :differs
        backup = File.join(backup_root, stamp, "#{src.name}.md")
        FileUtils.mkdir_p(File.dirname(backup))
        FileUtils.cp(res.target, backup, preserve: true)
        write_atomic(res.target, src.content)
        Result.new(name: res.name, target: res.target, status: :updated, backup: backup)
      end
    end
  end

  def write_atomic(path, content)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.binwrite(tmp, content)
    File.rename(tmp, path)
  ensure
    FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
  end

  def git_ls(root, rev)
    out, status = Open3.capture2("git", "-C", root, "ls-tree", "-r", "--name-only", rev, "--", "docs/agents/agents")
    raise SourceError, "git ls-tree #{rev} failed in #{root}" unless status.success?
    out.lines.map(&:chomp).grep(SOURCE_RE)
  end

  def git_show(root, rev, rel)
    out, status = Open3.capture2("git", "-C", root, "show", "#{rev}:#{rel}", binmode: true)
    raise SourceError, "git show #{rev}:#{rel} failed in #{root}" unless status.success?
    out
  end
end
