# frozen_string_literal: true

namespace :gate_runs do
  desc "Close every in-flight attempt on a retired gate (g1_cert), once; idempotent"
  # The release pipeline runs this as remove-dead-local-check-indicator's
  # post_deploy_cmd. A hook's verdict is its exit status, so a row that will not
  # save raises (update!) and the task exits non-zero rather than printing a count.
  task close_retired: :environment do
    closed = GateRun.close_retired_in_flight!
    left = GateRun.where(key: GateRun::RETIRED_KEYS).in_flight.count
    puts "[gate-runs] closed #{closed} in-flight retired gate run(s); #{left} still open"
    abort "[gate-runs] #{left} retired gate run(s) still in flight after the close" if left.positive?
  end
end
