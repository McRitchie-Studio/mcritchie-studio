# frozen_string_literal: true

require "English"
require "open3"

# HubMoveDiagnosis — turn "cannot load such file" into an error that says WHOSE
# bug it is.
#
# THE DEFECT (measured four times on 2026-09-10 across three sessions). Every
# desk-side command loads its libraries with `require_relative` against the
# checkout the SCRIPT lives in. When that checkout is the hub primary and
# another process moves it, the library file briefly does not exist and the
# running command dies:
#
#   bin/agent-worktree: cannot load such file -- bin/lib/desk_ledger
#   bin/agent-worktree: cannot load such file -- lib/desk_activity
#   bin/ship:           cannot load such file -- bin/lib/ci_wait
#
# WHY THE RAW ERROR IS THE PROBLEM. It is indistinguishable from a typo'd
# require, a half-finished merge, or a broken runtime — so the builder reads it
# as their own bug and starts debugging a diff that is fine. Every one of the
# four hits recovered on a plain re-run; the cost was never the failure, it was
# the misdiagnosis. This module exists to remove the misdiagnosis, and nothing
# else.
#
# HOW WIDE THE WINDOW ACTUALLY IS — the reason a "rare race" framing is wrong.
# Measured twice on a throwaway clone (2026-09-13), sampling each file ~300k
# times while a checkout ran: a single checkout takes ~0.5s and leaves a
# late-index file absent for 0.35-0.71s of it, ~68% of the operation. Files
# EARLY in the index (bin/agent-worktree) are absent for ~0ms and load fine;
# files later (bin/lib/*, bin/ship*) are absent for most of it. That ordering
# predicts the four incidents exactly: agent-worktree LAUNCHED and then failed
# on its LIBRARY, while bin/ship-wait vanished outright mid-launch.
#
# THERE IS NO RETRY HERE, DELIBERATELY. A retry cannot tell a transient checkout
# window from a genuinely missing file — a bad merge, a half-installed runtime,
# a typo — and would turn a loud, correct, instantly-recovered failure into a
# slow one with the cause hidden. This module only DIAGNOSES; the command still
# dies, and the operator still re-runs it.
#
# THE DISCRIMINATOR, and why it does not cry wolf. Three cases, and only two of
# them are a move:
#
#   1. The file EXISTS NOW but the require failed → it was absent moments ago
#      and is back. That is near-proof of a checkout completing under us.
#   2. The file is ABSENT NOW but present in HEAD → the working tree does not
#      currently match HEAD for a tracked file: a checkout is in flight.
#   3. The file is ABSENT NOW and not in HEAD → GENUINELY MISSING. Returns nil,
#      and the caller lets the ordinary LoadError stand untouched. A typo must
#      not be dressed up as an infrastructure hiccup.
module HubMoveDiagnosis
  module_function

  # Arm the diagnosis for the whole process, from ONE line at the top of a
  # script.
  #
  # WHY at_exit AND NOT a begin/rescue around the requires. The requires in these
  # scripts are interleaved with the comments that explain them, so wrapping the
  # block would re-indent thirty-odd lines and bury the change. More importantly
  # a wrapper only covers the requires it encloses, while this covers a LoadError
  # raised anywhere — including one a library raises transitively, several files
  # deep, which is precisely where the measured `bin/lib/desk_ledger` and
  # `lib/desk_activity` failures came from.
  #
  # IT SWALLOWS NOTHING. `$!` is read, never cleared, so the interpreter still
  # prints the original LoadError and its backtrace and the process still exits
  # non-zero. The diagnosis is printed ahead of it, on stderr, as context.
  def install!(root:, command: nil)
    at_exit do
      error = $ERROR_INFO
      if error.is_a?(LoadError) && (diagnosis = message_for(error, root: root, command: command))
        warn diagnosis
      end
    end
  end

  # A diagnosis for +error+, or nil when the file is genuinely missing and the
  # raw LoadError should stand. Never raises: an error path that itself blows up
  # is strictly worse than the error it was explaining.
  def message_for(error, root:, command: nil)
    path = missing_path(error)
    return nil unless path

    rel = relative_to(path, root)
    return nil unless rel

    present_now = File.exist?(path)
    in_head = tracked_in_head?(root, rel)
    return nil unless present_now || in_head

    build_message(rel: rel, root: root, command: command, present_now: present_now)
  rescue StandardError
    nil
  end

  # The path Ruby could not load. LoadError#path carries it directly; the
  # message is parsed only when it does not (a `require_relative` raising
  # through a wrapper can arrive with path nil).
  def missing_path(error)
    direct = error.respond_to?(:path) ? error.path : nil
    candidate = direct && !direct.to_s.strip.empty? ? direct.to_s : parse_path(error.message.to_s)
    return nil unless candidate
    return nil unless candidate.start_with?(File::SEPARATOR)

    File.extname(candidate).empty? ? "#{candidate}.rb" : candidate
  end

  def parse_path(message)
    match = message.match(/cannot load such file -+ (.+)\z/)
    match && match[1].strip
  end

  def relative_to(path, root)
    canonical_root = canonical(root)
    expanded = canonical(path)
    return nil unless expanded.start_with?("#{canonical_root}#{File::SEPARATOR}")

    expanded[(canonical_root.length + 1)..]
  end

  # Resolve symlinks WITHOUT requiring the path to exist.
  #
  # WHY THIS IS NOT `File.expand_path`. On macOS /var is a symlink to
  # /private/var, and `require_relative` reports the RESOLVED path while a
  # script's own `File.expand_path("..", __dir__)` reports the unresolved one.
  # Comparing those two directly makes the prefix test fail and the diagnosis
  # silently never fire — measured 2026-09-13, on a tmpdir, which is exactly
  # where the tests live. `File.realpath` alone cannot be used either: the
  # missing file is missing, so it raises. So resolve the nearest EXISTING
  # ancestor and re-attach the rest.
  def canonical(path)
    expanded = File.expand_path(path.to_s)
    suffix = []
    cursor = expanded
    until File.exist?(cursor) || File.dirname(cursor) == cursor
      suffix.unshift(File.basename(cursor))
      cursor = File.dirname(cursor)
    end
    base = begin
      File.realpath(cursor)
    rescue StandardError
      cursor
    end
    suffix.empty? ? base : File.join(base, *suffix)
  end

  # Does this path exist in the commit the checkout claims to be on? Tracked but
  # absent means a checkout is rewriting it; untracked means it was never there.
  def tracked_in_head?(root, rel)
    _out, status = Open3.capture2e("git", "-C", root.to_s, "cat-file", "-e", "HEAD:#{rel}")
    status.success?
  rescue StandardError
    false
  end

  # The repo's most recent HEAD move, as evidence the reader can check. This is
  # what makes the error SELF-diagnosing rather than merely sympathetic: a
  # reflog entry timestamped seconds ago is the smoking gun, and one timestamped
  # last week says look elsewhere.
  def last_head_move(root)
    out, status = Open3.capture2e("git", "-C", root.to_s, "reflog", "--date=iso", "-n", "1")
    return nil unless status.success?

    line = out.lines.first.to_s.strip
    line.empty? ? nil : line
  rescue StandardError
    nil
  end

  def build_message(rel:, root:, command:, present_now:)
    who = command ? "#{command} " : ""
    observation =
      if present_now
        "#{rel} EXISTS NOW but was missing when #{who}tried to load it — it was rewritten under the " \
          "running command."
      else
        "#{rel} is missing from the working tree but present in HEAD — a checkout is rewriting it right now."
      end

    lines = [
      "",
      "  THE HUB CHECKOUT MOVED UNDER THIS COMMAND — this is very probably NOT your bug.",
      "",
      "  #{observation}",
      "  Checkout: #{root}"
    ]
    move = last_head_move(root)
    lines << "  Last HEAD move: #{move}" if move
    lines.push(
      "",
      "  WHY. git checkout does not rewrite a file in place: it unlinks the path and creates it",
      "  afresh, so every tracked file this repo carries is briefly ABSENT while another process",
      "  moves the checkout. Measured on the hub primary: ~0.4-0.7s of absence per checkout.",
      "",
      "  REMEDY. Re-run the command. If it fails the same way twice, the checkout is not merely",
      "  passing through — inspect it (git -C #{root} status) before assuming a moved tree.",
      "",
      "  If you are on a desk that carries its own copy of this script, invoke THAT copy instead;",
      "  a desk is pinned to its own branch and nobody moves it under you.",
      ""
    )
    lines.join("\n")
  end
end
