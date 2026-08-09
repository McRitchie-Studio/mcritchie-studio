# frozen_string_literal: true

module Ci
  # Heals ingested workflow-run rows the FIRST-WRITE-WINS conclusion bug corrupted.
  #
  # Before GithubWorkflowRunIngestJob gated on `run_attempt`, a re-run — which
  # reuses the SAME run_id — could never update a recorded conclusion. Any run
  # whose flake a re-run fixed stayed `failure` here forever, and since
  # Ci::ReviewGate reads these rows and NOTHING else, those PRs read red on the
  # board while GitHub reported green: `bin/task claim-next-review` could not pop
  # them, permanently. That fix is FORWARD-ONLY — GitHub has already delivered
  # both attempts and will not re-deliver — so rows corrupted before it shipped
  # need this pass.
  #
  # This is an OPERATOR-RUN ONE-TIME HEAL, deliberately NOT a post_deploy_cmd.
  # The corruption is one-time and bounded; running this on every deploy would
  # spend ~1030 API calls (~6 min, measured at 339ms/call) inside every release,
  # forever, to correct 20 rows once. Run it by hand after the ingest fix ships:
  #   bin/rails ci:reconcile_workflow_runs DRY_RUN=1   # then again without
  #
  # GitHub is authoritative: this NEVER invents a verdict, it copies one, and only
  # when the remote run has actually concluded. Idempotent by construction — a
  # second run finds nothing to correct — and best-effort per row, because one
  # unreadable run (deleted, moved org, rate-limited) must not fail a deploy.
  module RunReconciler
    Result = Struct.new(:checked, :corrected, :unreadable, keyword_init: true)

    module_function

    def call(days: 30, dry_run: false, client: Github::Client.new, logger: Rails.logger, io: nil)
      result = Result.new(checked: 0, corrected: 0, unreadable: 0)

      candidates(days).find_each do |record|
        result.checked += 1
        remote = fetch(client, record)
        next unless remote

        correction = correction_for(record, remote)
        next unless correction

        io&.puts("  #{describe(record, correction)}")
        result.corrected += 1
        record.update!(correction) unless dry_run
      rescue StandardError => e
        result.unreadable += 1
        logger&.warn("[ci:reconcile] run #{record.run_id} skipped: #{e.class}: #{e.message}")
      end

      result
    end

    # Only TERMINAL rows can be stale in the way this heals: a non-terminal row has
    # no conclusion yet, and GitHub will still deliver its completion normally.
    def candidates(days)
      GithubWorkflowRun.where(status: "completed")
                       .where(created_at: days.days.ago..)
                       .order(created_at: :desc)
    end

    def fetch(client, record)
      body = client.get("repos/#{record.repo}/actions/runs/#{record.run_id}")
      body.is_a?(Hash) ? body : nil
    end

    # The attributes to write, or nil when the row already agrees with GitHub.
    # A run still in flight remotely is left alone — there is no verdict to copy.
    def correction_for(record, remote)
      return nil unless remote["status"].to_s == "completed"

      conclusion = remote["conclusion"].to_s.presence
      return nil if conclusion.blank?

      attempt = remote["run_attempt"].presence&.to_i
      return nil if conclusion == record.conclusion && attempt.to_i == record.run_attempt.to_i

      { conclusion: conclusion, run_attempt: attempt }
    end

    def describe(record, correction)
      "#{record.repo} run #{record.run_id} (#{record.head_branch}): " \
        "#{record.conclusion.inspect}/attempt #{record.run_attempt.inspect} → " \
        "#{correction[:conclusion].inspect}/attempt #{correction[:run_attempt].inspect}"
    end
  end
end
