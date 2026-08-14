# DevopsKeySpread — a task's devops hash populated with EVERY Task::DEVOPS_KEYS
# name, each in its real shape (a map key gets a map, a list key a list, the rest
# a string).
#
# It exists so the "a partial write must not delete the rest" tests can assert the
# PROPERTY over the model's key list instead of over today's spellings. A test
# that named `pr_urls` (the key whose loss surfaced the bug) or `agent_context`
# would keep passing while the NEXT key added to the model was still destroyed —
# the blacklist shape that bug was made of. Derived from DEVOPS_KEYS, a new key is
# covered the moment it is added.
#
# Values are REALISTIC on purpose: a junk string in `claim_expires_at`, or an
# acceptance bullet outside ACCEPTANCE_WORD_RANGE, fails on a model callback or a
# validation rather than on the behavior under test.
#
# Used by test/models/task_test.rb (Task.merge_devops_metadata) and
# test/controllers/tasks_controller_test.rb (the board UI edit path).
module DevopsKeySpread
  module_function

  def devops_key_spread
    Task::DEVOPS_KEYS.index_with do |key|
      case key
      when *Task::DEVOPS_MAP_KEYS then { "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/305" }
      when "acceptance" then ["This board edit preserves unlisted devops keys"]
      when *Task::DEVOPS_LIST_KEYS then ["stored-#{key}"]
      when "pr_url" then "https://github.com/McRitchie-Studio/mcritchie-studio/pull/836"
      when "kind" then "bug"
      when "shape" then "backend"
      when "claim_expires_at", "approval_requested_at", "approval_approved_at" then Time.current.utc.iso8601
      when "approval_status" then Task::OPERATOR_APPROVAL_NONE
      # Must name a REAL agent slug: Task#sync_persona_identity deletes an unknown
      # persona on save, which would quietly drop the key from a persisted spread.
      when "persona" then "alex"
      else "stored-#{key}"
      end
    end
  end
end
