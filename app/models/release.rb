class Release < ApplicationRecord
  # Workflow 2 — Deploy. A Release is a singleton: at most one is active
  # (assembling/assembled) at a time. It carries `reviewed` tasks onto a
  # disposable release branch, through QA, and to production.
  #   assembling → assembled → shipped   (+ abandoned)
  # The git/merge-queue mechanics live in the conductor tooling (a later task);
  # this model owns the state + the task membership.
  STATES = %w[assembling assembled shipped abandoned].freeze
  ACTIVE_STATES = %w[assembling assembled].freeze
  TERMINAL_STATES = %w[shipped abandoned].freeze

  # The per-repo integration branch. It is now PERSISTENT: every repo keeps a
  # single `release` branch that feature PRs merge INTO (membership flips at
  # merge), QA deploys from, and `ship` fast-forwards into `main`. main is always
  # an ancestor of `release`; on ship it collapses to main and re-accumulates.
  # (Was the disposable `release/<slug>` cut per candidate — see the cutover.)
  BRANCH = "release"

  has_many :tasks, foreign_key: :release_slug, primary_key: :slug, inverse_of: :release

  validates :slug, presence: true, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validate :at_most_one_active_release, if: :active?

  before_validation :generate_slug, on: :create
  before_save :set_state_timestamp, if: :state_changed?

  scope :active, -> { where(state: ACTIVE_STATES) }

  def to_param
    slug
  end

  # The current (singleton) active release, if any.
  def self.current
    active.order(created_at: :desc).first
  end

  # The release to feature on the board: the active one if any, else the most
  # recently shipped (so the header always reflects the latest release).
  def self.featured
    current || where(state: "shipped").order(Arel.sql("COALESCE(shipped_at, created_at) DESC")).first
  end

  # Open a new release candidate. Raises (singleton validation) if one is active.
  # Defaults the integration branch to the persistent `release` (overridable).
  def self.open!(attrs = {})
    create!({ branch: BRANCH }.merge(attrs).merge(state: "assembling"))
  end

  # The active release if one exists, else open a fresh one. The find-or-create
  # the merge-time membership path (Conductor#adopt!) leans on so a PR merging
  # into `release` always lands on an active candidate.
  def self.current_or_open!
    current || open!
  end

  def active?
    ACTIVE_STATES.include?(state)
  end

  # Member tasks in PRODUCER-FIRST order: gems (published) before apps
  # (deployed), honoring task `dependencies` within that. This is the order the
  # conductor publishes/deploys in and the order `member_plan` reports.
  def ordered_members
    Release::Ordering.producer_first(tasks.to_a)
  end

  def shipped?
    state == "shipped"
  end

  # Attach a reviewed task to this (assembling) release. The TASK's stage becomes
  # `assembled` (its PR is now riding the train) — the release's own state is
  # unchanged. The actual branch merge + per-merge tests are the conductor's job;
  # this is the membership + stage bookkeeping.
  def add(task)
    # On the durable `release` branch a PR can merge AFTER we've assembled (QA'd)
    # the candidate. That late merge must re-open the RC so it re-assembles and
    # re-QAs before shipping — so absorb an assembled state by reopening, rather
    # than refusing the member.
    reopen! if state == "assembled"
    raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"
    raise ArgumentError, "task #{task.slug} is not reviewed (stage: #{task.stage})" unless task.stage == "reviewed"

    task.update!(release_slug: slug, stage: "assembled")
    task
  end

  # Every member in + tests check out → the RC is complete.
  def assemble!
    raise ArgumentError, "release #{slug} is not assembling (state: #{state})" unless state == "assembling"

    update!(state: "assembled")
  end

  # The operator "Makes the release" → ship to prod; members flip to `shipped`.
  # Allowed from an active release (assembling or assembled); never from terminal.
  def ship!(by: nil)
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    transaction do
      update!(state: "shipped", confirmed_by: by, confirmed_at: Time.current)
      tasks.to_a.each(&:ship!)
    end
  end

  # Pull an assembled RC back to `assembling` so more reviewed work can be added.
  # Adding members invalidates the prior QA pass, so the RC must re-assemble (and
  # re-QA) before it can ship. This is what lets `Prepare release` be additive
  # instead of refusing when a release is already in flight.
  def reopen!
    raise ArgumentError, "release #{slug} is not assembled (state: #{state})" unless state == "assembled"

    update!(state: "assembling")
  end

  # Discard a stuck RC → members fall back to `reviewed` (off the train), and the
  # singleton frees up for a fresh release.
  #
  # NOTE: this only drops BOARD membership. On the DURABLE per-repo `release`
  # branch the git-side remediation — reverting each abandoned member's merge
  # commit on `release` (never a force-push, since `release` is permanent and
  # shared) — is owned by the conductor/CLI as a documented step. The model never
  # touches git.
  def abandon!
    raise ArgumentError, "release #{slug} is already terminal (state: #{state})" unless active?

    transaction do
      tasks.to_a.each { |task| task.update!(stage: "reviewed", release_slug: nil) }
      update!(state: "abandoned")
    end
  end

  private

  def at_most_one_active_release
    scope = Release.where(state: ACTIVE_STATES)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:state, "another release is already active") if scope.exists?
  end

  def set_state_timestamp
    case state
    when "assembled" then self.assembled_at = Time.current
    when "shipped"   then self.shipped_at = Time.current
    when "abandoned" then self.abandoned_at = Time.current
    end
  end

  def generate_slug
    self.slug ||= "rel-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3)}"
  end
end
