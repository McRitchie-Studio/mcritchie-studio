# frozen_string_literal: true

# WHAT A CHECK IS ALLOWED TO KNOW.
#
# The context is the whole surface. A check reads the task and the diff from here and
# reports through here — it never reaches back into bin/dor-check's top-level locals,
# instance variables or helper methods. That is what makes a check a file you can add,
# read and delete on its own, and it is what stops the plugin seam from decaying back
# into "everything is global, the files are just further apart now".
#
# THE OUTPUT CHANNELS ARE THREE, AND THEY ARE NOT INTERCHANGEABLE:
#   error   — refuses. The gate's verdict flips to not-ready.
#   suggest — never affects `ready`. Loud advice.
#   say     — operator-facing prose for TEXT mode only. It is BUFFERED here rather
#             than printed, because a --json consumer parses stdout and prose printed
#             beside the verdict corrupts the payload. bin/dor-check decides whether
#             to print. A check that called puts directly could not know that, and the
#             first version of the migration-collision check broke --json exactly that
#             way.
module Dor
  module Checks
    class Context
      attr_reader :gate, :gate_role, :task, :devops, :slug, :diff_root, :diff_base, :pr_url,
                  :changed_files, :errors, :suggestions, :lines

      def initialize(gate:, gate_role:, task:, devops:, slug:, diff_root:, diff_base:,
                     pr_url:, changed_files: [], json: false)
        @gate          = gate.to_s
        @gate_role     = gate_role.to_s
        @task          = task || {}
        @devops        = devops || {}
        @slug          = slug.to_s
        @diff_root     = diff_root
        @diff_base     = diff_base
        @pr_url        = pr_url.to_s
        @changed_files = Array(changed_files)
        @json          = json
        @errors        = []
        @suggestions   = []
        @lines         = []
      end

      def error(message)
        @errors << message.to_s
        self
      end

      def suggest(message)
        @suggestions << message.to_s
        self
      end

      # Buffered prose. Ignored entirely in --json mode, so a check may call it
      # unconditionally without knowing which mode it is running in.
      def say(*text)
        @lines.concat(Array(text).flatten.map(&:to_s)) unless @json
        self
      end

      def json?
        !!@json
      end

      # The review gate-zero is the AUTHORITATIVE CI verdict, so several checks are
      # deliberately stricter in this role than at submit. Asked as a question here so
      # a check never has to remember the string.
      def review_role?
        @gate_role == "review"
      end

      def merge_gate?
        @gate != "build"
      end
    end
  end
end
