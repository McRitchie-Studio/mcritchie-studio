# frozen_string_literal: true

require "io/wait"

# BoundedCommand — run one child with a deadline, and kill it when the deadline
# passes. The 1Password reads (bin/lib/op_meter.rb) and the dispatcher's harness
# probe (bin/lib/agent_mailbox/harness_probe.rb) both run through here.
#
# WHY. On 2026-10-21 the Mac rebooted and the 1Password cache daemon never
# became ready. Every `op read` then waited about fifteen minutes before it
# answered, and every caller waited with it: `gh` reported Bad credentials,
# `git fetch` hung, and nothing merged or shipped for three days. The callers
# used IO.popen(...).read, which has no deadline. This is the deadline.
#
# HOW. Process.spawn, stdout on a pipe read without blocking, and
# Process.waitpid2 with WNOHANG, until the child has exited and its stdout is
# closed, or the deadline passes. At the deadline the child gets SIGKILL (its
# whole process group when pgroup: true) and is reaped, so `$?` then holds a
# killed status that no caller reads as success. Timeout::timeout is not used:
# it raises into whatever the thread is doing and leaves the child running.
#
# Like IO.popen, it raises SystemCallError (Errno::ENOENT, Errno::EACCES) when
# the binary cannot be started, and `$?` after it returns is the child's status.
# Pure Ruby with no gems, because the bin/ tree travels on its own.
module BoundedCommand
  # Seconds. One beat of the dispatcher is sixty; a healthy `op read` takes a
  # few hundred milliseconds.
  DEFAULT_DEADLINE = 20
  # After the child exits, how long a grandchild that inherited stdout may keep
  # the pipe open before the read stops waiting for it.
  DRAIN_GRACE = 0.2
  CHUNK = 65_536

  # out: stdout as read so far. status: the Process::Status (killed on a
  # timeout). timed_out: the deadline passed and the child was killed.
  Result = Struct.new(:out, :status, :timed_out, keyword_init: true) do
    def timed_out? = timed_out == true
    def success? = !timed_out? && !status.nil? && status.success?
  end

  module_function

  # +env+ is merged into the child's environment, as IO.popen's first argument.
  # +argv+ is the command and its arguments; never run through a shell.
  # Remaining options go to Process.spawn (err:, chdir:, ...).
  def run(env, argv, deadline: DEFAULT_DEADLINE, pgroup: false, **spawn_opts)
    argv = Array(argv).map(&:to_s)
    reader, writer = IO.pipe
    opts = spawn_opts.merge(out: writer)
    opts[:pgroup] = true if pgroup
    begin
      # [cmd, argv0] keeps a one-element argv away from the shell.
      pid = Process.spawn(env || {}, [ argv.first, argv.first ], *argv.drop(1), **opts)
    rescue StandardError
      reader.close
      raise
    ensure
      writer.close unless writer.closed?
    end
    collect(pid, reader, deadline.to_f, pgroup)
  end

  def collect(pid, reader, deadline, pgroup)
    buf = +""
    limit = now + deadline
    status = nil
    eof = false
    exited_at = nil
    loop do
      status ||= Process.waitpid2(pid, Process::WNOHANG)&.last
      exited_at ||= now if status
      break if status && eof
      # The child is gone but something it started still holds stdout.
      break if status && now - exited_at >= DRAIN_GRACE
      return finish(buf, kill(pid, pgroup), true) if now >= limit

      wait = status ? DRAIN_GRACE : [ limit - now, 0.25 ].min
      eof = read_some(reader, buf, wait) if !eof && wait.positive?
      sleep 0.02 if eof && !status
    end
    finish(buf, status, false)
  ensure
    reader.close unless reader.closed?
  end

  # true at end of file.
  def read_some(reader, buf, wait)
    return false unless reader.wait_readable(wait)

    chunk = reader.read_nonblock(CHUNK, exception: false)
    return true if chunk.nil?

    buf << chunk unless chunk == :wait_readable
    false
  end

  def kill(pid, pgroup)
    begin
      Process.kill(:KILL, pgroup ? -pid : pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    begin
      Process.waitpid2(pid)&.last
    rescue Errno::ECHILD
      $?
    end
  end

  def finish(buf, status, timed_out)
    Result.new(out: buf.force_encoding(Encoding.default_external), status: status, timed_out: timed_out)
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
