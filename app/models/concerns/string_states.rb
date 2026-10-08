# The stage, status and state string columns and the one list each may hold.
#
# REGISTRY maps "table.column" to the model constant that is the vocabulary: the
# model's `inclusion:` validation reads that constant, and the column carries a
# CHECK constraint (`<table>_<column>_known`) holding the same values, so a write
# that skips validations (update_columns, update_all, insert_all, raw SQL) is
# refused by the database. A migration freezes its own copy of each list;
# test/models/state_check_constraints_test.rb fails when a constant, its
# validation and its constraint disagree, so a new value needs a new migration.
#
# A NULL passes a CHECK. Whether a column may be NULL is the column's own NOT
# NULL, which this registry does not decide.
module StringStates
  REGISTRY = {
    "agent_login_requests.status" => "AgentLoginRequest::STATUSES",
    "app_requests.status" => "AppRequest::STATUSES",
    "appearances.stage" => "Appearance::STAGES",
    "broadcasts.status" => "Broadcast::STATUSES",
    "contents.stage" => "Content::STAGES",
    "credential_records.status" => "CredentialRecord::STATUSES",
    "credential_vaults.status" => "CredentialVault::STATUSES",
    "desk_capture_items.status" => "DeskCaptureItem::STATUSES",
    "desk_records.status" => "DeskRecord::STATUSES",
    "import_runs.status" => "ImportRun::STATUSES",
    "music_videos.stage" => "MusicVideo::STAGES",
    "news.stage" => "News::STAGES",
    "release_events.status" => "ReleaseEvent::STATUSES",
    "releases.state" => "Release::STATES",
    "review_pending_actions.state" => "ReviewPendingAction::STATES",
    "source_documents.status" => "SourceDocument::STATUSES",
    "staged_emails.status" => "StagedEmail::STATUSES",
    "tasks.approval_status" => "Task::OPERATOR_APPROVAL_STATUSES",
    "tasks.block_kind" => "Task::BLOCK_KINDS",
    "tasks.merged" => "Task::MERGED_STATES",
    "tasks.stage" => "Task::STAGES",
    "tiktok_drafts.state" => "TiktokDraft::STATES",
    "triage_findings.prior_art" => "TriageFinding::PRIOR_ART_STATES",
    "triage_findings.status" => "TriageFinding::STATUSES",
    "video_clips.status" => "VideoClip::STATUSES",
    "video_stitches.state" => "VideoStitch::STATES",
    "workspace_accounts.status" => "WorkspaceAccount::STATUSES",
    "workspace_mailboxes.status" => "WorkspaceMailbox::STATUSES"
  }.freeze

  NO_LIST = "no model validation names its values; it takes a CHECK once a census of the live rows is clean".freeze
  PROVIDER = "holds a provider's own vocabulary, which changes without a release here".freeze
  ENGINE = "the table belongs to studio-engine, which owns its migrations".freeze
  # Every other string column named stage, status or state, with the reason it
  # carries no CHECK. The census (bin/rails state_checks:census) prints the values
  # each one holds.
  UNCONSTRAINED = {
    "agent_actions.stage" => "a copy of the task's stage at the time of the action; history keeps retired stages",
    "agent_activities.stage" => "a copy of the task's stage at the time of the activity; history keeps retired stages",
    "agents.status" => NO_LIST,
    "appearances.higgsfield_reference_status" => PROVIDER,
    "appearances.sheet_build_state" => NO_LIST,
    "apps.status" => NO_LIST,
    "arenas.state" => "geography: the state an arena stands in",
    "ci_check_jobs.status" => PROVIDER,
    "communications.status" => "validated on asks only; other kinds leave it unset",
    "contacts.verification_status" => PROVIDER,
    "contacts.verification_sub_status" => PROVIDER,
    "email_image_briefs.build_state" => NO_LIST,
    "games.status" => NO_LIST,
    "github_workflow_runs.status" => PROVIDER,
    "studio_knowledge_docs.status" => ENGINE,
    "task_events.from_stage" => "history: rows written before a stage retired keep its name",
    "task_events.to_stage" => "history: rows written before a stage retired keep its name",
    "tiktok_drafts.tiktok_status" => PROVIDER
  }.freeze

  COLUMN_NAME = /(\A|_)(stage|status|state)\z/

  Column = Struct.new(:table, :column, :constant, keyword_init: true) do
    def name = "#{table}.#{column}"
    def constraint = "#{table}_#{column}_known"
    def values = constant.constantize
    def model = constant.deconstantize.constantize
  end

  def self.columns
    REGISTRY.map do |name, constant|
      table, column = name.split(".")
      Column.new(table: table, column: column, constant: constant)
    end
  end

  # The registered column a constraint name belongs to, or nil.
  def self.for_constraint(name)
    columns.find { |column| column.constraint == name.to_s }
  end
end
