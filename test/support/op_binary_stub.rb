# frozen_string_literal: true

require "shellwords"

# OpBinaryStub — swaps a module's `op` binary path for a RECORDING STUB, so a
# test can assert HOW MANY 1Password reads a code path spends.
#
# WHY COUNTING READS IS THE ONLY HONEST ASSERTION HERE. The secret-resolution
# chain (bin/lib/task_board.rb#agent_secret, bin/lib/agent_api.rb#agent_secret)
# reads ENV, then the repo .env, then 1Password. In PRODUCTION all three hold
# the SAME string, so a test that asserts only the returned value passes
# identically on every ordering — which is exactly why the vault-second ordering
# survived unnoticed until it exhausted a 1,000/day account-wide cap through
# routine `bin/task` traffic. The stub therefore prints a DIFFERENT value than
# the .env fixture (so the source is legible in the return value) and records
# every invocation (so "was the vault consulted at all?" is answerable).
#
# WHY A REAL EXECUTABLE rather than a stubbed method. The chain reaches `op`
# through `File.executable?(OP)` and `IO.popen([OP, ...])` — a spawned process,
# not a Ruby call. A method mock would prove the code called the method it was
# written to call; a shell script on disk proves no process was spawned, which
# is the thing that costs a credential. It also keeps the test honest on a
# machine that HAS a real `op` on PATH: the constant is repointed, so a passing
# run can never be a run that quietly talked to the operator's live vault.
#
#   OpBinaryStub.with_stub(TaskBoard, dir: tmp) do |op|
#     TaskBoard.agent_secret(dotenv)
#     assert_equal 0, op.count
#   end
#
# `consts:` swaps additional constants for the block (AgentApi resolves its
# .env under REPO_ROOT, which in a test must not be the real repo).
module OpBinaryStub
  # The recording. `count` is the number of times the stub was EXECUTED; `lines`
  # are the argument strings it was executed with, so a test can also pin WHICH
  # secret was asked for.
  Recorder = Struct.new(:log) do
    def lines
      File.exist?(log) ? File.readlines(log).map(&:chomp) : []
    end

    def count
      lines.size
    end
  end

  module_function

  def with_stub(owner, dir:, prints: "from-vault", consts: {})
    log = File.join(dir, "op-calls.log")
    swaps = { OP: write_stub(dir, log, prints) }.merge(consts)
    originals = swaps.keys.to_h { |name| [name, owner.const_get(name)] }

    swaps.each { |name, value| swap_const(owner, name, value) }
    drop_memo(owner)
    yield Recorder.new(log)
  ensure
    originals&.each { |name, value| swap_const(owner, name, value) }
    drop_memo(owner)
  end

  # A shell script that appends its arguments to `log` and prints `prints`.
  def write_stub(dir, log, prints)
    path = File.join(dir, "op-stub")
    File.write(path, [
      "#!/bin/sh",
      "printf '%s\\n' \"$*\" >> #{Shellwords.escape(log)}",
      "printf '%s' #{Shellwords.escape(prints)}",
      ""
    ].join("\n"))
    File.chmod(0o755, path)
    path
  end

  def swap_const(owner, name, value)
    verbose = $VERBOSE
    $VERBOSE = nil
    owner.const_set(name, value)
  ensure
    $VERBOSE = verbose
  end

  # The vault result is memoized for the life of the process (a retry would
  # BILL), so the memo is dropped on BOTH edges of the block. Without this the
  # read counts would depend on which test ran first, and minitest randomizes
  # order — the counts would be right on some runs and wrong on others, which is
  # worse than being wrong every time.
  def drop_memo(owner)
    owner.reset_op_secret_cache! if owner.respond_to?(:reset_op_secret_cache!)
  end
end
