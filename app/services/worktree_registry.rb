# Reads the agent worktree registry snapshot written by `bin/agent-worktree
# snapshot --write` at <projects-root>/.agents/worktree-registry.json and exposes
# it to the /devops panel. Never raises on a missing/unparseable file — callers
# always get a safe wrapper (see #present?).
class WorktreeRegistry
  REGISTRY_RELATIVE_PATH = [".agents", "worktree-registry.json"].freeze

  class << self
    # Overridable so tests can point the reader at a fixture registry.
    attr_writer :registry_path

    def registry_path
      @registry_path ||= projects_root.join(*REGISTRY_RELATIVE_PATH)
    end

    # Reset to the Rails.root-derived default (used by tests teardown).
    def reset_registry_path!
      @registry_path = nil
    end

    def load(path = registry_path)
      data = JSON.parse(File.read(path))
      new(data)
    rescue StandardError => e
      Rails.logger.warn("[WorktreeRegistry] load failed: #{e.class}: #{e.message}")
      new(nil)
    end

    # Best-effort: re-run the snapshot generator, then load. Any failure (missing
    # script, non-zero exit, raise) degrades to whatever is already on disk.
    def refresh!
      run_snapshot
      load
    end

    private

    def run_snapshot
      Dir.chdir(hub_dir) do
        system("bin/agent-worktree", "snapshot", "--write", out: File::NULL, err: File::NULL)
      end
    rescue StandardError => e
      Rails.logger.warn("[WorktreeRegistry] refresh failed: #{e.class}: #{e.message}")
      false
    end

    # Parent of the canonical hub (projects/mcritchie-studio). Works whether Rails
    # boots from the hub or from a .worktrees/<task> checkout — no hardcoded path.
    def projects_root
      root = Rails.root.to_s
      hub = if root.include?("/.worktrees/")
        Pathname.new(root.sub(%r{/\.worktrees/.*\z}, ""))
      else
        Rails.root
      end
      hub.parent
    end

    def hub_dir
      projects_root.join("mcritchie-studio")
    end
  end

  def initialize(data)
    @data = data.is_a?(Hash) ? data : nil
  end

  def present?
    @data.present?
  end

  def empty?
    !present?
  end

  def generated_at
    raw = self["generated_at"]
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def capacity
    self["capacity"] || {}
  end

  def redis_db_range
    self["redis_db_range"] || {}
  end

  def summary
    self["summary"] || {}
  end

  def worktrees
    self["worktrees"] || []
  end

  def apps
    self["apps"] || []
  end

  def projects_dir
    self["projects_dir"]
  end

  # Map redis_db => worktree entry, for the capacity slot visual.
  def worktrees_by_redis_db
    @worktrees_by_redis_db ||= worktrees.each_with_object({}) do |wt, acc|
      db = wt["redis_db"]
      acc[db] = wt if db
    end
  end

  private

  def [](key)
    @data && @data[key]
  end
end
