# frozen_string_literal: true

require_relative "../checks"
require_relative "../../migration_collision"
require_relative "../../ci_status"
require "json"

# DUPLICATE MIGRATION INSTALL — the merge gate's read.
#
# Rails groups migrations by CLASS NAME, never by filename, so two files under
# different timestamps that parse to one class raise DuplicateMigrationNameError on
# EVERY db:migrate — including the Heroku release phase, which takes the deploy down
# with it. Three of these were caught by hand on 2026-08-13 before they merged.
#
# WHY THE MERGE GATE, when session-preflight already reports this at build time and
# bin/ship at handoff: both judge ONE branch against the base at the moment they run,
# and neither can see the case this exists for — two branches, each honestly clean
# when it was certified, that collide only once the FIRST one merges. The merge gate
# is the last read before `accepted` takes both, which is why the sibling-PR leg below
# is load-bearing and not decoration: without it, two simultaneous PRs both pass.
#
# THIS FILE IS ALSO THE PLUGIN SEAM'S FIRST INHABITANT. It was chosen to migrate
# because it is self-contained — it reads the diff and the PR and nothing else — so
# the move proves the seam without entangling it with the gate's shared state. Note
# what adding it costs now: this file, and nothing else. No require line, no registry
# entry, no hook in bin/dor-check. That is the whole point.
module Dor
  module Checks
    class MigrationCollision < Base
      def self.phase
        :merge
      end

      def call(context)
        @context = context
        items = collision_items
        return if items.empty?

        # The operator block is BUFFERED through the context, which drops it in --json
        # mode. Printing it directly corrupted the payload the first time this shipped.
        context.say(::MigrationCollision.lines(items))
        context.error(refusal(items))
      end

      private

      attr_reader :context

      def refusal(items)
        detail = items.first(3).map { |item|
          number = item["number"] ? " (PR ##{item["number"]})" : ""
          "#{File.basename(item.dig("mine", "path").to_s)} vs " \
            "#{File.basename(item.dig("theirs", "path").to_s)} — #{item["label"]}#{number}"
        }.join("; ")

        "duplicate migration install: #{items.size} collision(s) — #{detail}. Two migrations " \
          "resolving to one Rails class raise DuplicateMigrationNameError on every db:migrate, including the " \
          "Heroku release phase. Rename one migration (a new timestamp is not enough — the CLASS must differ), " \
          "or drop the duplicate copy"
      end

      # Collisions between the migrations this change installs and every other copy
      # that will exist on `accepted` once it lands: the base ref (minus what this
      # change removes), every OTHER open PR, and the change itself (a mis-resolved
      # rebase leaves two installs in one diff).
      def collision_items
        status = status_read
        # `installs`, NOT `local_installs`. The latter drops any path its reader cannot
        # open, because in a WORKING TREE an unreadable path means the file was deleted
        # and a deleted migration is not an install. This gate reads a PULL REQUEST: the
        # added migration lives on the PR's branch and is routinely absent from whatever
        # root the gate runs in, so that rule would silently find nothing — which is
        # exactly how this check passed a real collision the first time it was wired.
        # Deletions arrive explicitly here (status[:removed]), so disk presence carries
        # no information worth losing. Heads are still read when they happen to be
        # readable, because provenance is what catches two copies of ONE ENGINE
        # migration; without it the class key alone still catches the raise.
        ours = status ? ::MigrationCollision.installs(status[:added], heads(status[:added])) : []
        return [] if ours.empty?

        removed = Array(status[:removed])
        sources = []
        base = context.diff_base
        if base
          base_installs = ref_installs(base).reject { |install| removed.include?(install["path"]) }
          sources << { "label" => "already on #{base}", "kind" => "branch", "installs" => base_installs }
        end
        sources.concat(sibling_pr_sources)
        sources << { "label" => "this branch", "kind" => "self", "installs" => ours }

        ::MigrationCollision.report(ours, sources)
      end

      # The migrations this change INSTALLS and the ones it REMOVES.
      #
      # A SECOND, narrow read rather than a widening of pr_file_read: that list is
      # deliberately status-free because its consumer (the doc-only classifier) must
      # see both sides of a rename as plain paths. Here the status IS the subject — a
      # migration the change removes is not an install, and a rename is a removal plus
      # an install.
      def status_read
        @status_read ||= (injected_status || pr_status || local_status)
      end

      # DOR_CHECK_PR_MIGRATIONS is the test seam, mirroring DOR_CHECK_PR_FILES: newline
      # "<status>\t<path>" records, exactly the shape the gh --jq below emits.
      def injected_status
        raw = ENV["DOR_CHECK_PR_MIGRATIONS"]
        raw && parse_status(raw)
      end

      def pr_status
        owner, repo, number = pr_coordinates
        return nil unless owner

        # A rename emits BOTH records — the destination as an install, the source as a
        # removal — so a renamed migration cannot read as a collision with its own old
        # copy on the base ref.
        raw, ok = CiStatus.gh_read_status(
          "api", "--paginate", "repos/#{owner}/#{repo}/pulls/#{number}/files", "--jq",
          '.[] | "\(.status)\t\(.filename)", (if .status == "renamed" then "removed\t\(.previous_filename // "")" else empty end)'
        )
        ok ? parse_status(raw) : nil
      end

      # The local leg. `--no-renames` is deliberate and is the whole reason the removal
      # set is tracked: with rename detection ON, git reports a moved migration as a
      # single R record and the old path never appears, so the base-ref copy this
      # change DELETES still looks live and the branch collides with itself. Under
      # --no-renames the move is a delete plus an add, and subtracting the delete from
      # the base ref is what makes a rename a non-event.
      def local_status
        root = context.diff_root
        base = context.diff_base
        return nil if root.nil? || base.nil?

        out = IO.popen(["git", "-C", root.to_s, "diff", "--name-status", "--no-renames", "#{base}...HEAD"],
                       err: File::NULL, &:read)
        return nil unless $?.success?

        parse_status(out.each_line.map { |line|
          state, path = line.strip.split(/\s+/, 2)
          "#{state.to_s.start_with?("D") ? "removed" : "added"}\t#{path}"
        }.join("\n"))
      rescue SystemCallError
        nil
      end

      def parse_status(raw)
        added = []
        removed = []
        raw.to_s.each_line do |line|
          state, path = line.strip.split("\t", 2)
          next if path.nil? || path.strip.empty?

          (state.to_s.strip == "removed" ? removed : added) << path.strip
        end
        { added: added, removed: removed }
      end

      # Provenance headers for whichever paths this root can actually read. Absent
      # files are simply omitted — the identity still stands on its class key.
      def heads(paths)
        Array(paths).each_with_object({}) do |path, acc|
          head = read_head(path)
          acc[path] = head if head
        end
      end

      def read_head(path)
        File.open(File.join(context.diff_root.to_s, path), &:readline).to_s
      rescue StandardError
        nil
      end

      def ref_installs(base)
        ::MigrationCollision.ref_installs(base) do |args|
          out = IO.popen(["git", "-C", context.diff_root.to_s, *args], err: File::NULL, &:read)
          $?.success? ? out : ""
        end
      rescue SystemCallError
        []
      end

      # Every OTHER open PR's migration installs. DOR_CHECK_SIBLING_PRS is the test
      # seam: a JSON array of {number,title,url,headRefName,files}. Release batch heads
      # are skipped — an `accepted → release` promote re-lists migrations already on
      # the base ref, and counting them would refuse every branch during a sweep.
      def sibling_pr_sources
        injected = ENV["DOR_CHECK_SIBLING_PRS"]
        prs = injected ? (JSON.parse(injected) rescue []) : fetch_sibling_prs

        mine = context.pr_url[%r{/pull/(\d+)}, 1].to_s
        Array(prs).filter_map do |pr|
          next if pr["number"].to_s == mine
          next if RELEASE_BATCH_HEAD_NAMES.include?(pr["headRefName"].to_s)

          installs = ::MigrationCollision.installs(Array(pr["files"]))
          next if installs.empty?

          { "label" => pr["title"].to_s, "kind" => "pr", "number" => pr["number"],
            "url" => pr["url"].to_s, "installs" => installs }
        end
      end

      RELEASE_BATCH_HEAD_NAMES = %w[accepted release].freeze

      # Addressed by `-R owner/repo` off the task's own pr_url, NOT by running gh
      # inside a directory: gh_read_status takes an argv and no chdir, and the gate is
      # explicitly allowed to run from a root that is not the task's repo. The PR url
      # is the one coordinate that is always right about which repo this task lands in.
      def fetch_sibling_prs
        owner, repo, = pr_coordinates
        return [] unless owner

        slug = "#{owner}/#{repo}"
        raw, ok = CiStatus.gh_read_status("pr", "list", "-R", slug, "--state", "open", "--limit", "50",
                                          "--json", "number,title,url,headRefName")
        return [] unless ok

        (JSON.parse(raw) rescue []).map do |pr|
          files, fok = CiStatus.gh_read_status("pr", "view", pr["number"].to_s, "-R", slug, "--json", "files")
          pr.merge("files" => fok ? ((JSON.parse(files)["files"] || []).map { |f| f["path"].to_s } rescue []) : [])
        end
      end

      def pr_coordinates
        context.pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})&.captures
      end
    end
  end
end
