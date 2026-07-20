# frozen_string_literal: true

require "test_helper"

# Wiring tripwire for the seal's boot-window retry (rel-20260720-c06235): the
# ship's step 5c (production_smoke_seal in bin/release.rb) must route its
# bin/prod-smoke run THROUGH Release::SealRetry — first failure waits ~30s and
# retries ONCE; only a persisting failure seals red — while bin/prod-smoke
# itself stays an honest single-shot standalone tool (the retry is caller-side
# BY DESIGN). Unwire the retry, move it into bin/prod-smoke, or drop the
# retry note from the seal summary and these fail. The retry POLICY itself is
# unit-tested in test/models/release/seal_retry_test.rb.
class SealRetryWiringTest < ActionDispatch::IntegrationTest
  RELEASE_SRC = Rails.root.join("bin", "release.rb")
  SMOKE_SRC   = Rails.root.join("bin", "prod-smoke")

  # The production_smoke_seal function body: from its def to the next top-level def.
  def seal_step_source
    src = File.read(RELEASE_SRC)
    body = src[/^def production_smoke_seal.*?(?=^def )/m]
    assert body, "bin/release.rb defines production_smoke_seal (step 5c)"
    body
  end

  test "[integration] bin/release.rb requires the seal_retry model alongside smoke_seal" do
    src = File.read(RELEASE_SRC)
    assert_includes src, 'require_relative "../app/models/release/seal_retry"',
      "the Rails-free retry policy loads standalone, like smoke_seal/prod_smoke"
  end

  test "[integration] the seal step runs bin/prod-smoke THROUGH Release::SealRetry.run" do
    body    = seal_step_source
    run_at  = body.index("Release::SealRetry.run")
    smoke_at = body.index('run_test_scope("prod_smoke_seal"')

    assert run_at,   "production_smoke_seal wires the boot-window retry via Release::SealRetry.run"
    assert smoke_at, "production_smoke_seal still runs the smoke via run_test_scope('prod_smoke_seal', ...)"
    assert_operator run_at, :<, smoke_at,
      "the smoke invocation sits INSIDE the SealRetry.run block (retry wraps the run)"
  end

  test "[integration] a green-after-retry seal summary carries the retry note" do
    assert_match(/retried once after .*boot-window wait/, seal_step_source,
      "the seal summary notes the boot-window retry so the board/notes verdict is honest")
  end

  test "[integration] bin/prod-smoke stays a single-shot standalone tool — no caller-side retry leaked in" do
    smoke = File.read(SMOKE_SRC)
    assert_no_match(/SealRetry/, smoke, "the retry lives in bin/release.rb's seal step, not the tool")
    assert_no_match(/\bsleep\b/, smoke, "bin/prod-smoke never sleeps — it reports one honest verdict")
  end
end
