class TriageController < ApplicationController
  # Reading the inbox is open (like the boards); promote/dismiss MINT or retire
  # board state, so they are operator-only — the same admin gate as task edits.
  skip_before_action :require_authentication, only: [:index]
  before_action :require_admin, except: [:index]

  def index
    @findings = TriageFinding.open_findings
    @resolved = TriageFinding.resolved.limit(20)
  end

  # Promote a finding into a real task. The task is born `designed` with the
  # finding's body as its agent_context, so the builder that claims it inherits
  # the discovery verbatim; the finding stamps its linkage and leaves the inbox.
  def promote
    finding = TriageFinding.find_by!(slug: params[:slug])
    task = Task.new(
      title: params[:title].presence || finding.title,
      stage: "designed",
      metadata: { "devops" => Task.normalize_devops_metadata(
        "kind" => params[:kind].presence || "chore",
        "repositories" => [finding.repo].compact_blank,
        "agent_context" => "Promoted from triage #{finding.slug} (source: #{finding.source.presence || 'unknown'}). #{finding.body}"
      ) }
    )
    if task.save
      finding.promote!(task)
      redirect_to triage_path, notice: "Promoted to task #{task.slug}."
    else
      redirect_to triage_path, alert: "Promote failed: #{task.errors.full_messages.join(', ')}"
    end
  end

  def dismiss
    finding = TriageFinding.find_by!(slug: params[:slug])
    finding.dismiss!
    redirect_to triage_path, notice: "Dismissed #{finding.slug}."
  end
end
