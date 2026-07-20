class Release
  # ONE caller-side retry around the production smoke SEAL's bin/prod-smoke run
  # (bin/release step 5c, production_smoke_seal).
  #
  # WHY (rel-20260720-c06235): the seal runs seconds after the Actions deploy,
  # so a smoke landing inside the dyno boot/restart window can fail against a
  # HEALTHY prod (GET /tasks non-OK, 5/5 green on re-run minutes later). The
  # policy: a first-attempt pass returns immediately (never sleeps); a first
  # failure waits ~30s for the boot window and retries EXACTLY ONCE; only a
  # persisting failure stays red. The seal's contract is untouched — it remains
  # non-blocking and never auto-rolls-back.
  #
  # The retry lives HERE — caller-side — BY DESIGN, so bin/prod-smoke stays an
  # honest single-shot standalone tool (one run, one verdict, no sleeps).
  #
  # Pure + Rails-FREE (like Release::SmokeSeal / Release::ProdSmoke) so
  # bin/release can `require_relative` it standalone and the policy stays
  # unit-testable: the block runs one smoke attempt and returns [out, ok];
  # `sleeper`/`on_retry` inject so tests never wait wall-clock seconds.
  module SealRetry
    module_function

    # ~30s covers the observed dyno boot/restart window without meaningfully
    # delaying the ship's closing beats (the seal is already post-deploy).
    DELAY_SECONDS = 30

    # Raised INSTEAD of really sleeping when the suite's guard is armed.
    class RealSleepError < StandardError; end

    # The real-sleep guard. A test that forgets to inject a `sleeper` would
    # silently burn 30 wall-clock seconds; relying on every caller remembering
    # is a CONVENTION, not a guarantee. test_helper arms SEAL_RETRY_NO_SLEEP=1
    # suite-wide, so a forgotten sleeper RAISES immediately and names the fix.
    # Production never sets it — there the boot window is a real wait.
    NO_SLEEP_ENV = "SEAL_RETRY_NO_SLEEP".freeze

    def default_sleeper
      return Kernel.method(:sleep) unless ENV[NO_SLEEP_ENV] == "1"

      lambda do |seconds|
        raise RealSleepError,
              "SealRetry tried to REALLY sleep #{seconds}s under test — inject a sleeper " \
              "(SealRetry.run(sleeper: ->(s) { ... })) instead of delaying the suite."
      end
    end

    # The final verdict: `out`/`ok` are the LAST attempt's smoke output +
    # pass/fail; `retried` flags that the verdict came after the boot-window
    # wait (the seal summary notes it either way — a green ride-through or a
    # confirmed-persistent red).
    Result = Struct.new(:out, :ok, :attempts, :retried, keyword_init: true)

    # Yields the attempt number (1, then at most 2); the block returns
    # [out, ok]. `on_retry` fires once, before the sleep, so the ship log
    # announces the wait as it starts.
    def run(delay: DELAY_SECONDS, sleeper: nil, on_retry: nil)
      sleeper ||= default_sleeper
      out, ok = yield(1)
      return Result.new(out: out, ok: ok, attempts: 1, retried: false) if ok

      on_retry&.call(delay)
      sleeper.call(delay)
      out, ok = yield(2)
      Result.new(out: out, ok: ok, attempts: 2, retried: true)
    end
  end
end
