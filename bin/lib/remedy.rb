# frozen_string_literal: true

# Remedy is the one helper every printed remedy hint goes through.
#
# A remedy hint is a command a script hands its reader to run: "Re-run
# <bin>/fast-check <slug>", "Run: <bin>/agent-worktree new <app> <task>", `eval
# "$(<bin>/gh-auth-refresh --export)"`. The reader pastes it, so it has to run from
# wherever they stand. Every hub tool (submit, task, dor-check, fast-check,
# agent-worktree, release, gh-token, ...) lives in mcritchie-studio/bin alone, so a
# bare `bin/<script>` runs only from a hub checkout; typed on a satellite or gem desk
# it fails with `No such file or directory`.
#
# This module renders each hint from the real command name and makes two kinds of
# drift impossible:
#
#   1. A hint is always absolute. resolve_bin returns an absolute path whatever it
#      is given; there is no bare form to fall back to.
#   2. A hint names only a real script. The script must be an executable in the bin/
#      directory beside this file, the same tree the speaking script runs from. A
#      renamed or retired script raises UnknownScript when the hint is built, and most
#      hints are built as constants when their script loads, so a stale name fails
#      every test that loads the file, not a reader's paste.
#
# What is not a remedy, and so does not come through here:
#
#   - a usage banner (it describes the grammar the reader just typed; banners use
#     $PROGRAM_NAME),
#   - a step transcript (bin/submit's `say "5/8 pre-flight — running ..."`),
#   - a script named as a subject in prose ("could not be read (bin/task show)"),
#   - a field written into the board (`"cmd" => "bin/dor-check <slug> --gate ..."`),
#     where an absolute path would stamp one laptop's layout into shared records,
#   - an argv a script executes itself (`Open3.capture2e("bin/agent-worktree", ...)`).
#
# Which copy of a script: resolution follows the filesystem. resolve_bin takes the
# first of `bin_dirs` that carries an executable by that name, and otherwise the last
# directory, so the reader still gets an absolute path they can reason about.
#
#   A re-run hint names a script for the tree the speaker is already in, so it passes
#   one directory: the speaking script's own __dir__. It names the very script that is
#   talking, and its siblings beside it.
#
#   A handoff hint names a script for a different tree (`bin/task begin` runs at the
#   hub and points at the desk it just made), so it passes the desk's bin first and
#   the hub's second. bin/submit resolves its gates from its own __dir__, and a primary
#   routinely lags `accepted`, so desk-first keeps every hub task on its desk's gates.
#
# A re-run hint carries no `cd`: the reader is already standing in the tree. A handoff
# leads with `cd <desk> &&`, because the path picks the script and the cwd picks the
# tree it acts on (TaskTree refuses a pre-flight rooted anywhere but the task's desk).
#
# A dir inside the fixed-path tooling install is named by its stable link (see
# stable_bin_dir), so a pasted hint does not pin a SHA the next ship prunes.
module Remedy
  # The bin/ this file ships in. Its executables are the scripts a hint may name.
  HOME_BIN = File.expand_path("..", __dir__)

  # A hint named a script that does not exist in this tree.
  class UnknownScript < ArgumentError; end

  module_function

  # The executables a hint may name: every runnable file directly in HOME_BIN.
  # Read from the disk, so adding or retiring a script needs no edit here.
  def scripts
    Dir.children(HOME_BIN).select do |name|
      path = File.join(HOME_BIN, name)
      File.file?(path) && File.executable?(path)
    end.sort
  end

  # Raises UnknownScript unless +script+ is an executable in HOME_BIN.
  def known!(script)
    name = script.to_s
    path = File.join(HOME_BIN, name)
    return name if !name.empty? && !name.include?("/") && File.file?(path) && File.executable?(path)

    raise UnknownScript, "no executable bin/#{name} in #{HOME_BIN}; a remedy must name a real script"
  end

  # The absolute path of +script+ in the first of +bin_dirs+ that carries it, else
  # in the last one. With no dirs it is the copy in HOME_BIN.
  def resolve_bin(script, *bin_dirs)
    name = known!(script)
    dirs = bin_dirs.flatten.compact.map(&:to_s).reject { |dir| dir.strip.empty? }
    dirs = [HOME_BIN] if dirs.empty?
    dirs = dirs.map { |dir| stable_bin_dir(File.expand_path(dir)) }

    candidates = dirs.map { |dir| File.join(dir, name) }
    candidates.find { |path| File.executable?(path) } || candidates.last
  end

  # bin/install-agent-docs installs the tooling at <state>/tooling/<sha>/ (stamped
  # `.complete`) and points the symlink <state>/bin at <sha>/bin. A script running
  # from there sees its own __dir__ as the SHA-pinned path; when the link currently
  # resolves to that same directory, name the link. Any other dir, or a link that has
  # moved on, is returned unchanged. It only reads (a realpath comparison).
  def stable_bin_dir(dir)
    tree = File.dirname(dir)
    tooling = File.dirname(tree)
    return dir unless File.basename(dir) == "bin" && File.basename(tooling) == "tooling"
    return dir unless File.file?(File.join(tree, ".complete"))

    link = File.join(File.dirname(tooling), "bin")
    File.symlink?(link) && File.realpath(link) == File.realpath(dir) ? link : dir
  rescue SystemCallError
    dir
  end

  # The hint itself: the resolved script, then the operands the reader pastes.
  # `bin_dirs` is one directory (a re-run) or an ordered list (a handoff). Blank args
  # are dropped, so a conditional flag never leaves a double space in the command.
  def command(script, bin_dirs, *args)
    parts = [resolve_bin(script, bin_dirs)]
    parts.concat(args.flatten.map(&:to_s).reject { |arg| arg.strip.empty? })
    parts.join(" ")
  end

  # The line `bin/task begin` prints last: `cd <desk> && <submit> <slug>`. The desk's
  # own bin/submit when it carries an executable one (every hub desk does), else the
  # hub's.
  def handoff(slug, worktree_dir, hub_bin_dir)
    "cd #{worktree_dir} && #{command('submit', [File.join(worktree_dir.to_s, 'bin'), hub_bin_dir], slug)}"
  end

  # `eval "$(<bin>/gh-auth-refresh --export)"` refreshes GH_TOKEN, the variable `gh`
  # reads. Use it when the failed read was a `gh` call.
  def gh_auth_refresh(bin_dirs)
    %(eval "$(#{command('gh-auth-refresh', bin_dirs, '--export')})")
  end

  # `export <ENV>="$(<bin>/gh-token)"` sets the variable a Ruby GitHub read consumes.
  # The consumer picks the variable: callers pass their reader's own constant
  # (Github::AppToken::FALLBACK_TOKEN_ENV), so the spelling cannot drift from what it
  # refreshes; see bin/lib/github_read_remedy.rb. The quotes keep a token from
  # word-splitting, and an empty name refuses rather than defaulting.
  def token_export(env_name, bin_dirs)
    name = env_name.to_s.strip
    raise ArgumentError, "token_export needs the env var the read consumes" if name.empty?

    %(export #{name}="$(#{resolve_bin('gh-token', bin_dirs)})")
  end
end
