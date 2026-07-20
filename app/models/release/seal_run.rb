class Release
  # The post-ship smoke seal's VERDICT COMPOSITION: run the smoke through the
  # boot-window retry (Release::SealRetry), then fold the outcome into the
  # persisted 🟢/🔴 seal (Release::SmokeSeal) with an honest summary.
  #
  # WHY IT EXISTS: bin/release step 5c used to build the summary and the seal
  # inline, so the ONLY thing a test could assert about the retry's effect on
  # the recorded verdict was the SCRIPT'S SOURCE TEXT. Composed here, the real
  # behavior is testable — "a boot-window transient records a GREEN seal that
  # says it retried" is now an assertion about objects, not about a grep.
  # bin/release keeps exactly what a script should own: IO, chdir, telemetry.
  #
  # Pure + Rails-FREE (like SealRetry / SmokeSeal / ProdSmoke) so bin/release
  # can `require_relative` it with no Rails boot.
  module SealRun
    module_function

    # `out` is the FINAL attempt's smoke output (what the ship log shows);
    # `seal` is the SmokeSeal to record; `retried` says the verdict came after
    # the boot-window wait; `attempts` is 1 or 2.
    Result = Struct.new(:out, :ok, :seal, :retried, :attempts, keyword_init: true)

    # Yields the attempt number; the block runs ONE smoke and returns [out, ok].
    # `error` (optional callable) supplies the last attempt's error message for
    # a red summary — bin/release passes the SystemCallError it degraded.
    def call(host:, delay: SealRetry::DELAY_SECONDS, sleeper: nil, on_retry: nil, error: nil, checked_at: nil, &smoke)
      result = SealRetry.run(delay: delay, sleeper: sleeper, on_retry: on_retry, &smoke)
      seal   = SmokeSeal.from_result(
        passed: result.ok,
        summary: summary_for(ok: result.ok, host: host, retried: result.retried, delay: delay, error: error&.call),
        **(checked_at ? { checked_at: checked_at } : {})
      )

      Result.new(out: result.out, ok: result.ok, seal: seal, retried: result.retried, attempts: result.attempts)
    end

    # The one-line verdict the board, release notes, and Discord all read.
    # The retry note rides BOTH verdicts on purpose: green says "this took a
    # retry" (not a clean first pass), red says "this SURVIVED the retry" — a
    # confirmed failure, not a boot-window blip.
    def summary_for(ok:, host:, retried:, delay: SealRetry::DELAY_SECONDS, error: nil)
      note = retried ? " (retried once after #{delay}s boot-window wait)" : ""
      return "@qa-readonly green vs #{host}#{note}" if ok

      "@qa-readonly FAILED vs #{host}#{note} — #{error || 'see ship log'}"
    end
  end
end
