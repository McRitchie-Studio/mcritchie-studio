module Api
  module V1
    # Gate-run writes — open / append-sop / close for the branded testing gates
    # (GateRun::GATES: G1 Cert … G4 Ship) on a task or release, plus a read of a
    # subject's runs. All writes flow through GateRun's own funnel
    # (open!/append_sop!/close!) so attempt semantics live in ONE place.
    #
    # Deliberately NO usage gate here: gate markers are deterministic pipeline
    # boundaries, not usage-bearing work events — the same rationale as
    # `bin/task checkpoint`'s source=system default. Do NOT re-add a
    # MISSING_EVENT_USAGE-style requirement; producers (bin/full-suite-check,
    # bin/dor-check, bin/pr-review, bin/release) post fire-and-forget.
    class GateRunsController < BaseController
      before_action :set_subject
      before_action :validate_key!, except: :index

      def open
        run = GateRun.open!(**common_args)
        render_data(run, status: :created)
      end

      def append_sop
        run = GateRun.append_sop!(**common_args.except(:metadata), sop: sop_params)
        render_data(run, status: :created)
      end

      def close
        if params[:success].nil?
          return render_error("success is required (true|false)", error_code: "MISSING_SUCCESS")
        end

        run = GateRun.close!(
          **common_args,
          success: ActiveModel::Type::Boolean.new.cast(params[:success]),
          sops: sops_params
        )
        render_data(run, status: :created)
      end

      def index
        render_data(GateRun.for_subject(subject_type, subject_slug).chronological)
      end

      private

      def subject_type
        params[:subject_type].to_s
      end

      def subject_slug
        params[:subject_slug].to_s
      end

      def gate_key
        params[:key].to_s
      end

      # A gate post must land on a REAL task/release — a late or mistyped post
      # must never mint gate rows for a subject that doesn't exist.
      def set_subject
        found =
          case subject_type
          when "task" then Task.exists?(slug: subject_slug)
          when "release" then Release.exists?(slug: subject_slug)
          end
        return if found

        render_error("#{subject_type} not found", status: :not_found, error_code: "NOT_FOUND")
      end

      def validate_key!
        unless GateRun::KEYS.include?(gate_key)
          return render_error("unknown gate key #{gate_key.inspect} (one of: #{GateRun::KEYS.join(', ')})",
                              error_code: "INVALID_GATE_KEY")
        end
        return if GateRun::GATES.dig(gate_key, "grain") == subject_type

        render_error("#{gate_key} is a #{GateRun::GATES.dig(gate_key, 'grain')}-grain gate, not #{subject_type}",
                     error_code: "GATE_GRAIN_MISMATCH")
      end

      def common_args
        {
          subject_type: subject_type,
          subject_slug: subject_slug,
          key: gate_key,
          actor: payload[:actor].presence,
          source: payload[:source].presence || "system",
          metadata: payload[:metadata].to_h
        }
      end

      def sop_params
        payload[:sop].to_h
      end

      def sops_params
        Array(payload[:sops]).map(&:to_h)
      end

      def payload
        raw = params[:gate]
        raw = params unless raw.is_a?(ActionController::Parameters)
        @payload ||= raw.permit(
          :actor, :source,
          metadata: {},
          sop: GateRun::SOP_KEYS.map(&:to_sym),
          sops: GateRun::SOP_KEYS.map(&:to_sym)
        )
      end
    end
  end
end
