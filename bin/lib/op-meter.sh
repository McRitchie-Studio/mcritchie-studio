# shellcheck shell=bash
# bin/lib/op-meter.sh — the BASH half of OpMeter. Sourced, never executed.
#
#   . "$(dirname "$0")/lib/op-meter.sh"
#   op_metered "$OP" read "op://$VAULT/$ITEM/app-id"
#
# Same seven-column TSV as bin/lib/op_meter.rb, same file, same order. One log
# format, two writers, one reader (bin/op-reads). See the Ruby half for WHY this
# exists — the 247 unattributed reads of 2026-08-31, and the fact that it was the
# second time the same diagnosis had to be re-derived from scratch.
#
# ── WHAT THIS MAY NOT DO ──────────────────────────────────────────────────────
#
# NOT COST A READ. Nothing here executes `op`, and nothing here reads a
# credential. An instrument that consumes the quota it measures is worse than no
# instrument. test/lib/op_meter_test.rb proves it by running the whole path with
# `op` replaced by a recording stub and asserting the stub ran ZERO times.
#
# NOT BREAK THE CALLER. Every consumer of `op` in this stack has a working
# fallback for a rate-limited or absent `op` — the ecosystem ran a full-day
# 1Password outage on those fallbacks — so metering may never cost them that.
# `op_metered` returns the child's EXACT exit status and passes stdout/stderr
# through untouched; every write here is `|| true`-terminated; and a failure to
# log is never a failure to run. Proven with a booby-trapped `op` that exits 127.
#
# NOT SPAWN MORE THAN IT MUST. bin/gh-app-git-credential runs on every push and
# fetch, so the hot path is deliberately builtin-only apart from one `date` and
# the perl watchdog that bounds each attempt (THE BOUND, below). The
# sandbox check short-circuits on an empty TASK_USAGE_SANDBOX before it reaches
# `tr`, so a real agent session pays nothing for the test-only branch.
#
# ── THE SANDBOX RULE (rule 1 of lib/task_usage_sandbox.rb) ─────────────────────
# When the sandbox is ARMED, the destination must be PINNED; an unpinned fallback
# reaches the operator's real store and is REFUSED. Same rule, same spellings and
# same case-insensitivity as the Ruby half, because a guard whose two halves
# disagree about whether it is on is a guard nobody can reason about.
#
# Rule 2 (a pin aimed back INSIDE the real store) is NOT re-derived here, for the
# reason bin/statusline gives for the same omission: proving it means resolving
# the real root through ProjectsRoot — which climbs out of .worktrees — and
# comparing on a separator boundary. That is Ruby, and hand-rolling a second copy
# in shell is how the two halves drift apart. LAYER 3 of
# test/lib/state_store_containment_test.rb watches the BYTES of a stand-in store
# instead, which catches what no source scan can.

# THE CALLING SCRIPT, captured HERE — at source time, at top level — and never
# read again from inside a function. That is not a style preference, it is a zsh
# bug this got wrong first: zsh's FUNCTION_ARGZERO (on by default) rebinds $0 to
# the FUNCTION NAME inside a function body, so reading `${0##*/}` in the recorder
# logged `op_meter_record` for every zsh caller. bin/setup-1pass-token is
# #!/bin/zsh, so the one attribution this whole file exists to produce was the
# one it silently got wrong — a log full of confident, useless rows.
#
# bash: $0 at top level of a sourced file is the PARENT script (what we want).
# zsh:  $0 there is the SOURCED FILE, so use $ZSH_ARGZERO, the script as invoked.
# OP_METER_CALLER overrides both, for a caller that knows better than its argv —
# a credential helper git spawns by absolute path, say.
if [ -n "${OP_METER_CALLER:-}" ]; then
  op_meter_caller="$OP_METER_CALLER"
elif [ -n "${ZSH_VERSION:-}" ]; then
  op_meter_caller="${ZSH_ARGZERO:-$0}"
else
  op_meter_caller="$0"
fi
op_meter_caller="${op_meter_caller##*/}"
[ -n "$op_meter_caller" ] || op_meter_caller="-"

# Resolve the log into op_meter_log — assigns rather than echoes, because a
# command substitution here would fork on every metered call.
op_meter_resolve_log() {
  op_meter_log="${MCR_OP_READS_LOG:-}"
  if [ -z "$op_meter_log" ]; then
    op_meter_log="${CLAUDE_PROJECTS_DIR:-$HOME/projects}/.agents/op-reads.log"
  fi
}

# 0 = refuse the write, 1 = proceed. (Shell truth: 0 is success/"yes, refuse".)
op_meter_refused() {
  # The common case is a real agent session with the sandbox unset. Answer it
  # with a builtin test and return BEFORE forking `tr`.
  [ -z "${TASK_USAGE_SANDBOX:-}" ] && return 1

  local armed
  armed=$(printf '%s' "${TASK_USAGE_SANDBOX:-}" | tr '[:upper:]' '[:lower:]')
  case "$armed" in
    ""|0|false|no|off) return 1 ;;
  esac

  # Armed but PINNED — the destination is provable, so write normally. Test
  # fixtures pin CLAUDE_PROJECTS_DIR and MUST keep recording; failing closed on
  # the happy path would be worse than the leak it closes.
  [ -n "${MCR_OP_READS_LOG:-}" ] && return 1
  [ -n "${CLAUDE_PROJECTS_DIR:-}" ] && return 1

  return 0
}

# op_meter_record <action> <exit-status|timeout> [via]
# Best-effort by contract: always returns 0, whatever happens.
op_meter_record() {
  local action="${1:--}" rc="${2:-}" via="${3:--}"
  op_meter_refused && return 0

  local op_meter_log
  op_meter_resolve_log
  local dir="${op_meter_log%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0

  local outcome="ok"
  case "$rc" in
    0) ;;
    timeout) outcome="timeout" ;;
    *) outcome="fail:${rc:-?}" ;;
  esac

  # op_meter_caller is the SCRIPT that sourced this file (captured at source
  # time — see the zsh note above), which is the attribution being asked for:
  # "which command spent the reads", not "which library".
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${op_meter_caller:--}" \
    "${action:--}" \
    "$outcome" \
    "${via:--}" \
    "$$" \
    "${MCR_OP_METER_CONTEXT:-${CLAUDE_CODE_SESSION_ID:--}}" \
    >>"$op_meter_log" 2>/dev/null || true
  return 0
}

# THE BOUND (2026-10-24, tightened 2026-10-28). On 2026-10-21 the Mac rebooted,
# the 1Password cache daemon never became ready, and every `op read` waited about
# fifteen minutes: bin/gh-app-git-credential runs on every fetch and push, so git
# hung with it. Each attempt now gets MCR_OP_DEADLINE seconds (default 14, the
# Ruby half's OpMeter::DEFAULT_DEADLINE, so an attempt and its retry stay under
# thirty seconds), then SIGKILL; a timed-out attempt is recorded as `timeout` and
# retried ONCE with OP_CACHE=false, which skips the daemon.
#
# The watchdog is perl because `timeout` is not installed on this Mac and perl
# is on every macOS and Linux box. It uses NO alarm at all: op is a Go binary
# that ignores SIGALRM, and an alarm is the wrong shape for a bound anyway. The
# parent forks, the child starts its own process group and execs op, and the
# parent polls waitpid(WNOHANG) every 50 ms until the child exits or the
# deadline passes, then SIGKILLs the whole GROUP (anything op forked dies with
# it, so no helper is left holding the caller's `$(...)` pipe open).
# The child keeps the caller's process group only when stdin is a terminal (an
# interactive `op signin` must stay in the foreground group to read it); then
# the kill reaches op alone, which SIGKILL still ends.
# Exit 124 is the watchdog's timeout (GNU timeout's code); 127 and 126 are the
# shell's not-found and not-executable, so the log keeps one vocabulary.
OP_METER_TIMEOUT_RC=124
# The exit a caller uses after a hung read (EX_TEMPFAIL); OpMeter::HUNG_EXIT.
OP_METER_HUNG_RC=75
# shellcheck disable=SC2016
OP_METER_WATCHDOG='use POSIX ();
use Time::HiRes ();
my $t = shift @ARGV;
$t = ($t =~ /^[0-9]*[.]?[0-9]+$/ && $t > 0) ? $t : 14;
my $own = !(-t STDIN);
my $pid = fork;
exit 126 unless defined $pid;
if ($pid == 0) { POSIX::setpgid(0, 0) if $own; exec { $ARGV[0] } @ARGV; POSIX::_exit($!{ENOENT} ? 127 : 126); }
POSIX::setpgid($pid, $pid) if $own;
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { kill "KILL", ($own ? -$pid : $pid); waitpid $pid, 0; exit 130; };
my $limit = Time::HiRes::time() + $t;
while (1) {
  my $r = waitpid($pid, POSIX::WNOHANG());
  if ($r == $pid) { my $s = $?; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8); }
  exit 126 if $r < 0;
  if (Time::HiRes::time() >= $limit) { kill "KILL", ($own ? -$pid : $pid); waitpid $pid, 0; exit 124; }
  Time::HiRes::sleep(0.05);
}'

# op_meter_bounded <op-binary> <args...> — one attempt under the deadline. With
# no perl the attempt runs unbounded, as every caller did before the bound.
op_meter_bounded() {
  if command -v perl >/dev/null 2>&1; then
    perl -e "$OP_METER_WATCHDOG" "${MCR_OP_DEADLINE:-14}" "$@"
  else
    "$@"
  fi
}

# op_meter_hung_line — the one loud line for a hung read, on stderr. The same
# words as OpMeter::HUNG_LINE. op_metered prints it itself when both attempts
# run out; a caller that sent op_metered's stderr to /dev/null prints it again.
op_meter_hung_line() {
  echo "✗ 1Password is not answering: an \`op\` read was killed after two bounded attempts. Quit and reopen the 1Password app; reboot if that fails. Then re-run (bin/release prepare and ship can wait for it: --wait-for-1password)." >&2
}

# op_metered <op-binary> <args...> — run `op` and record it.
#
# THE SEAM. Call sites use this instead of the binary directly, so a new one gets
# metering by construction rather than by remembering. stdout and stderr are the
# child's own (no capture, no pipe — a pipe would break `op`'s own behaviour and
# add a fork), and the return is the child's exact status.
op_metered() {
  local op_meter_bin="$1"; shift

  # "item get" / "vault list" are two words; "read" / "whoami" are one. Record
  # what was ASKED FOR — flattening `op item get` to `item` loses the axis that
  # maps onto the quota.
  local op_meter_action="${1:--}"
  case "${1:-}" in
    item|vault|document|account|service-account|user|group|connect|events-api)
      case "${2:-}" in
        ""|-*) ;;
        *) op_meter_action="$1 $2" ;;
      esac
      ;;
  esac

  # `|| rc=$?` keeps this safe under `set -e`: a non-zero `op` must reach the
  # recorder and the caller, not abort the shell from inside the wrapper.
  local op_meter_rc=0
  op_meter_bounded "$op_meter_bin" "$@" || op_meter_rc=$?

  if [ "$op_meter_rc" = "$OP_METER_TIMEOUT_RC" ]; then
    op_meter_record "$op_meter_action" timeout "${OP_METER_VIA:--}"
    op_meter_rc=0
    OP_CACHE=false op_meter_bounded "$op_meter_bin" "$@" || op_meter_rc=$?
  fi

  if [ "$op_meter_rc" = "$OP_METER_TIMEOUT_RC" ]; then
    op_meter_record "$op_meter_action" timeout "${OP_METER_VIA:--}"
    # Once per shell: a second hung read in the same run adds nothing.
    if [ -z "${OP_METER_HUNG_SAID:-}" ]; then
      OP_METER_HUNG_SAID=1
      op_meter_hung_line
    fi
  else
    op_meter_record "$op_meter_action" "$op_meter_rc" "${OP_METER_VIA:--}"
  fi
  return $op_meter_rc
}
