require Rails.root.join("bin/lib/ci_cause_detector").to_s

module Ci
  # A ONE-TIME BOARD HEAL for the cause cards filed before task ci-cause-card-dedupe-census
  # (task ci-cause-board-cleanup). That task fixed the filer going forward; this repairs
  # what it left on the board. Two repairs, in this order:
  #
  #   1. MERGE TWINS. Two CiCauseCardJob runs for one red raced and filed a base card and
  #      its `-2` for the same cause (turf run 42745469708: web-server-boot and -2, 123ms
  #      apart). Cards of one cause that share an occurrence id are one card: the earliest
  #      open one keeps the union of occurrences (else the earliest), and each twin is
  #      emptied, marked `merged_into`, and archived. A `-2` with NO shared occurrence is a
  #      genuine reopening (the shipped fix did not hold) and is left alone.
  #
  #   2. RE-KEY PAST NATIVE CRASHES. Before the native-abort key, a native crash under the
  #      test server was filed as web-server-boot (or as the census's own job). An
  #      occurrence on a harness card whose stored evidence matches the native-abort pattern moves to the
  #      repo's native-abort card, and so does a census (executed-set) occurrence of the
  #      same run attempt, which follows it as attempt_causes would file it today. A card
  #      left with no occurrences is marked `moved_to` and archived.
  #
  # The native-abort card it lands on is the open one, else the newest of that cause.
  # When none exists, it is created in the source card's stage if that card is closed
  # (a crash already closed out is history, not new work), else `designed`.
  #
  # DRY RUN BY DEFAULT and IDEMPOTENT: `call` returns the plan; only `apply: true` writes,
  # and a second run finds nothing to do. Each write holds the same per-cause advisory
  # lock as Ci::CauseCard#file!, so a live filer waits rather than racing it.
  # Run by `bin/rails ci:causes:cleanup` (lib/tasks/ci.rake). Operator step after ship.
  class CauseCleanup
    NATIVE_ABORT_KEY = "native-abort"
    CLOSED = Ci::CauseCard::CLOSED_STAGES
    MAX_OCCURRENCES = Ci::CauseCard::MAX_OCCURRENCES

    Action = Struct.new(:kind, :from, :to, :occurrence_ids, :note, keyword_init: true) do
      def to_s = "#{kind}: #{from} -> #{to} [#{occurrence_ids.join(', ')}]#{" (#{note})" if note}"
    end

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(apply: false, io: nil)
      @apply = apply
      @io = io
    end

    def call
      actions = merge_twins + rekey_native_crashes
      actions.each { |a| @io&.puts("#{@apply ? 'applied' : 'would apply'} #{a}") }
      actions
    end

    private

    def cause_cards
      Task.where("metadata ? 'ci_cause'").order(:id).to_a
    end

    def occurrences(task) = Array(task.metadata.dig("ci_cause", "occurrences"))
    def occurrence_ids(task) = occurrences(task).map { |o| o["id"] }
    def cause_of(task) = task.metadata["ci_cause"].to_h.transform_keys(&:to_sym).then { |c| c.merge(klass: c[:class]) }
    def base_of(task) = CiCauseDetector.card_slug(task.metadata.dig("ci_cause", "repo"), cause_of(task))

    # 1. Cards of one cause that share an occurrence: one keeper, the rest twins.
    def merge_twins
      cause_cards.group_by { |t| base_of(t) }.flat_map do |base, cards|
        clusters(cards.reject { |t| occurrence_ids(t).empty? }).flat_map do |cluster|
          keeper = cluster.find { |t| !CLOSED.include?(t.stage) } || cluster.first
          (cluster - [keeper]).map do |twin|
            ids = occurrence_ids(twin)
            write(base) { merge!(Task.find(keeper.id), Task.find(twin.id)) }
            Action.new(kind: "merge", from: twin.slug, to: keeper.slug, occurrence_ids: ids)
          end
        end
      end
    end

    # Cards linked by a shared occurrence id, in id order.
    def clusters(cards)
      cards.each_with_object([]) do |card, out|
        ids = occurrence_ids(card)
        joined = out.select { |c| c.any? { |t| (occurrence_ids(t) & ids).any? } }
        out.reject! { |c| joined.include?(c) }
        out << (joined.flatten + [card]).sort_by(&:id)
      end
    end

    def merge!(keeper, twin)
      keep = occurrences(keeper)
      add = occurrences(twin).reject { |o| keep.any? { |k| k["id"] == o["id"] } }
      shared = occurrences(twin).size - add.size
      meta = keeper.metadata.deep_dup
      cause = meta["ci_cause"]
      cause["occurrences"] = (keep + add).sort_by { |o| o["seen_at"].to_s }.last(MAX_OCCURRENCES)
      cause["count"] = cause["count"].to_i + twin.metadata.dig("ci_cause", "count").to_i - shared
      union_repos!(meta, twin.metadata)
      keeper.update!(metadata: meta)
      empty!(twin, "merged_into" => keeper.slug)
    end

    # 2. Occurrences whose evidence is a native crash, on a card keyed otherwise.
    def rekey_native_crashes
      cards = cause_cards
      native = cards.select { |t| rekeyable?(t) }.flat_map do |card|
        occurrences(card).select { |o| native_crash?(o) }.map { |o| [card, o, nil] }
      end
      followers = native.flat_map do |crash_card, crash, _|
        cards.reject { |t| t == crash_card }.flat_map do |card|
          next [] unless census?(card)

          occurrences(card).select { |o| same_attempt?(o, crash) }.map { |o| [card, o, crash["job"]] }
        end
      end
      (native + followers).uniq { |_, o, _| o["id"] }.map do |card, occ, follows|
        repo = occ["repo"].presence || card.metadata.dig("ci_cause", "repo")
        target = CiCauseDetector.card_slug(repo, klass: "harness", key: NATIVE_ABORT_KEY)
        to = write(target, base_of(card)) { move!(Task.find(card.id), occ, repo, target, follows) }
        Action.new(kind: "rekey", from: card.slug, to: to || target, occurrence_ids: [occ["id"]],
                   note: follows && "follows #{follows}")
      end
    end

    # Only a HARNESS card, as the detector reads it: a native crash is a harness fault,
    # and the detector reads the harness table only when no test is named. A test or
    # product card whose excerpt prints crash words (a test that shells out) stays put.
    def rekeyable?(card)
      cause = card.metadata["ci_cause"]
      cause["class"] == "harness" && cause["key"] != NATIVE_ABORT_KEY
    end

    def native_crash?(occ)
      pattern = CiCauseDetector::NATIVE_ABORT
      Array(occ["evidence"]).any? { |line| line.to_s.match?(pattern) }
    end

    def census?(card) = card.metadata.dig("ci_cause", "key").to_s.delete_prefix("job:").match?(CiCauseDetector::ECHO_JOB)

    # "run/attempt/job": two occurrences of one red attempt share the first two parts.
    def same_attempt?(a, b) = a["id"].to_s.split("/").first(2) == b["id"].to_s.split("/").first(2) && a["repo"] == b["repo"]

    def move!(source, occ, repo, target, follows)
      dest = native_card(target, source, repo)
      moved = occ.merge("follows" => follows).compact
      meta = dest.metadata.deep_dup
      cause = meta["ci_cause"]
      list = Array(cause["occurrences"])
      unless list.any? { |o| o["id"] == moved["id"] }
        cause["occurrences"] = (list + [moved]).sort_by { |o| o["seen_at"].to_s }.last(MAX_OCCURRENCES)
        cause["count"] = cause["count"].to_i + 1
        union_repos!(meta, source.metadata)
        dest.update!(metadata: meta)
      end
      remove!(source, occ["id"], dest.slug)
      dest.slug
    end

    # The repo's native-abort card: the open one, else the newest, else a new one.
    def native_card(target, source, repo)
      cards = Task.where(slug: target).or(Task.where("slug ~ ?", "^#{Regexp.escape(target)}-[0-9]+$")).order(:id)
      cards.where.not(stage: CLOSED).last || cards.last || create_native!(target, source, repo)
    end

    def create_native!(slug, source, repo)
      stage = CLOSED.include?(source.stage) ? source.stage : "designed"
      cause = { klass: "harness", key: NATIVE_ABORT_KEY, reason: CiCauseDetector::NATIVE_ABORT_REASON, evidence: [] }
      Ci::CauseCard.build(repo: repo, cause: cause, slug: slug, stage: stage).tap(&:save!)
    end

    def remove!(source, id, dest_slug)
      meta = source.metadata.deep_dup
      cause = meta["ci_cause"]
      cause["occurrences"] = Array(cause["occurrences"]).reject { |o| o["id"] == id }
      cause["count"] = [cause["count"].to_i - 1, 0].max
      cause["moved_to"] = (Array(cause["moved_to"]) | [dest_slug])
      source.update!(metadata: meta)
      source.archive! if cause["occurrences"].empty? && !CLOSED.include?(source.stage)
    end

    def empty!(twin, mark)
      meta = twin.metadata.deep_dup
      meta["ci_cause"].merge!("occurrences" => [], "count" => 0, **mark)
      twin.update!(metadata: meta)
      twin.archive! unless CLOSED.include?(twin.stage)
    end

    def union_repos!(meta, other)
      cause = meta["ci_cause"]
      cause["repos"] = Array(cause["repos"].presence || cause["repo"]) | Array(other.dig("ci_cause", "repos"))
      devops = meta["devops"] ||= {}
      devops["repositories"] = Array(devops["repositories"]) | Array(other.dig("devops", "repositories"))
    end

    # One transaction per repair, under Ci::CauseCard's per-cause lock(s). Dry run: nothing.
    def write(*bases)
      return unless @apply

      Task.transaction do
        bases.uniq.sort.each { |b| Ci::CauseCard.serialize!(b) }
        yield
      end
    end
  end
end
