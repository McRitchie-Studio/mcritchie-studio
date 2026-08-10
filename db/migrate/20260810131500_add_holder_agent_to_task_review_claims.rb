# The reviewing SOUL (carl / shannon / …), stored beside the session+nonce that
# already identify the live INSTANCE. The claim knew WHICH terminal held a review
# but never WHO, so the board could not paint a face from it — the crew seat had
# to wait for a separate `bin/reviewer-select` call that only one launcher makes.
class AddHolderAgentToTaskReviewClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :task_review_claims, :holder_agent, :string
  end
end
