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
  #
  # The agent_context leads with PRIOR ART because promotion is where a finding
  # stops being a note and starts being a brief someone works from — and a brief
  # is exactly how the framing in finding-6a5fdcd157b3 propagated. An
  # uninvestigated finding hands its builder the caveat, not a clean slate.
  def promote
    finding = TriageFinding.find_by!(slug: params[:slug])
    # Open-only: a double-submit or stale tab must not mint a second task.
    return redirect_to(triage_path, alert: "#{finding.slug} is already #{finding.status}.") unless finding.status == "open"

    task = Task.new(
      title: params[:title].presence || finding.title,
      stage: "designed",
      metadata: { "devops" => Task.normalize_devops_metadata(
        "kind" => params[:kind].presence || "chore",
        "repositories" => [finding.repo].compact_blank,
        "agent_context" => "Promoted from triage #{finding.slug} (source: #{finding.source.presence || 'unknown'}). " \
                           "PRIOR ART: #{finding.prior_art_context}. #{finding.body}"
      ) }
    )
    # Atomic + logged: a stamping failure rolls the minted task back (no orphan)
    # and lands in ErrorLog with the finding as target (house write discipline).
    saved = rescue_and_log(target: finding) { Task.transaction { task.save && finding.promote!(task) } }
    if saved
      redirect_to triage_path, notice: "Promoted to task #{task.slug}."
    else
      redirect_to triage_path, alert: "Promote failed: #{task.errors.full_messages.join(', ')}"
    end
  end

  def dismiss
    finding = TriageFinding.find_by!(slug: params[:slug])
    return redirect_to(triage_path, alert: "#{finding.slug} is already #{finding.status}.") unless finding.status == "open"

    rescue_and_log(target: finding) { finding.dismiss! }
    redirect_to triage_path, notice: "Dismissed #{finding.slug}."
  end
end
