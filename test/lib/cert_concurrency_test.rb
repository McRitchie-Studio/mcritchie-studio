# frozen_string_literal: true

# Unit + integration test for CertConcurrency — the worker cap that keeps
# concurrent local certs from over-subscribing the CPU. Plain Ruby (no Rails);
# also picked up by `bin/rails test`.
#
#   bin/rails test test/lib/cert_concurrency_test.rb   (stub needs minitest/mock via bundler)

require "minitest/autorun"
require "minitest/mock"
require_relative "../../bin/lib/cert_concurrency"

class CertConcurrencyTest < Minitest::Test
  # ---- [unit] worker_cap: usable cores split across peers, floored at 1 -------

  def test_solo_cert_leaves_two_cores_of_headroom
    assert_equal 8, CertConcurrency.worker_cap(cores: 10, peers: 1)
  end

  def test_two_concurrent_certs_split_usable_cores
    assert_equal 4, CertConcurrency.worker_cap(cores: 10, peers: 2)
  end

  def test_more_peers_shrink_the_share
    assert_equal 2, CertConcurrency.worker_cap(cores: 10, peers: 4)
  end

  def test_never_below_one_worker
    assert_equal 1, CertConcurrency.worker_cap(cores: 4, peers: 5)  # usable 2 / 5 = 0 -> 1
    assert_equal 1, CertConcurrency.worker_cap(cores: 2, peers: 1)  # usable 0 -> 1
    assert_equal 1, CertConcurrency.worker_cap(cores: 1, peers: 1)  # usable -1 -> 1
  end

  def test_zero_or_nil_peers_treated_as_one
    assert_equal 8, CertConcurrency.worker_cap(cores: 10, peers: 0)
    assert_equal 8, CertConcurrency.worker_cap(cores: 10, peers: nil)
  end

  # ---- [integration] parallel_workers composes cores + live peer count -------

  def test_parallel_workers_composes_processor_count_and_peer_count
    CertConcurrency.stub(:processor_count, 10) do
      CertConcurrency.stub(:active_peer_certs, 2) do
        assert_equal 4, CertConcurrency.parallel_workers
      end
    end
  end

  # ---- [integration] active_peer_certs across the `ps` boundary (mocked) ------

  def test_active_peer_certs_counts_only_real_cert_processes
    listing = [
      "/bin/zsh -c eval 'cd x && bin/full-suite-check task-a'",  # the LAUNCHER — not a cert
      "ruby bin/full-suite-check task-a",                        # a real cert
      "ruby /repo/.worktrees/b/bin/full-suite-check task-b",    # a second concurrent cert
      "ugrep -G full-suite-check",                               # a search — not a cert
      "/usr/sbin/coreaudiod"
    ].join("\n") + "\n"
    CertConcurrency.stub(:process_listing, listing) do
      assert_equal 2, CertConcurrency.active_peer_certs, "launcher + search lines carry the marker but are not certs"
    end
  end

  def test_active_peer_certs_floors_at_one_when_none_match
    CertConcurrency.stub(:process_listing, "/usr/sbin/coreaudiod\n/sbin/launchd\n") do
      assert_equal 1, CertConcurrency.active_peer_certs
    end
  end

  def test_active_peer_certs_is_one_when_the_process_listing_is_empty
    CertConcurrency.stub(:process_listing, "") do
      assert_equal 1, CertConcurrency.active_peer_certs
    end
  end
end
