# frozen_string_literal: true

module Devops
  # Nudges the qa-chatter Discord channel when a prod deploy enters the
  # operator-approval gate, so a waiting deploy never again sits silent (an actual
  # deploy waited 3h34m unseen — /tasks/board-deploy-approval-ux). Posts the DevOps
  # progress webhook (`DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`, the qa-chatter channel
  # per docs/agents/system/devops-cycle-design.md §5), reusing the release-notes
  # Discord transport.
  #
  # SAFE BY CONTRACT: a missing webhook is a no-op, and any delivery failure is
  # logged to ErrorLog and swallowed — this rides an after-the-fact webhook ingest,
  # so it must NEVER raise back into the job and roll the committed upsert.
  class DeployApprovalNotifier
    # The qa-chatter progress channel. Named here so config and docs share one
    # source of truth; falls back to the release-notes channel only if the
    # dedicated progress webhook is unset (older environments).
    def self.webhook_url
      ENV["DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL"].presence ||
        ENV["DISCORD_RELEASE_NOTES_WEBHOOK_URL"].presence
    end

    # Post the pending-approval nudge for +run+. Returns true if a message was
    # delivered, false if skipped (no webhook / no run) or on a handled failure.
    def self.notify_pending(run)
      new(run).notify_pending
    end

    def initialize(run)
      @run = run
    end

    def notify_pending
      return false if @run.nil?

      url = self.class.webhook_url
      return false if url.blank?

      ReleaseNotes::DiscordClient.deliver(content: content, webhook_url: url)
      true
    rescue StandardError => e
      ErrorLog.capture!(e)
      false
    end

    private

    # A deterministic, terse template with the facts an approver needs: what is
    # waiting, where, and the one-click board link. 🟡 mirrors the design doc's
    # "awaiting approval" message class.
    def content
      env = @run.pending_environment.presence || "production"
      lines = [
        "🟡 **Prod deploy awaiting approval** — `#{@run.workflow_name.presence || 'Production Deploy'}`" \
          " on `#{@run.repo}` (#{env})."
      ]
      lines << context_line if context_line.present?
      lines << "Approve on the board: #{board_url}"
      lines << "Run: #{@run.html_url}" if @run.html_url.present?
      lines.join("\n")
    end

    def context_line
      parts = []
      parts << "`#{@run.head_sha[0, 7]}`" if @run.head_sha.present?
      parts << @run.head_branch if @run.head_branch.present?
      parts.any? ? parts.join(" · ") : nil
    end

    def board_url
      "#{host}/deployments"
    end

    def host
      ENV["APP_HOST_URL"].presence || "https://mcritchie.studio"
    end
  end
end
