# A write the database refuses (a foreign key or a unique index) answers 422 with
# the reason, never a 500: the slug columns carry foreign keys, so a destroy that
# would strand children, a write naming a row that does not exist, or a slug that
# is already taken all reach here when no model validation caught them first.
#
# HTML goes back where it came from with the reason as the alert; JSON gets
# `{ error:, error_code: "CONSTRAINT_VIOLATION" }`. Include it after the
# StandardError catch-all, since rescue_from tries the last declaration first.
module ConstraintViolationResponses
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique, with: :handle_constraint_violation
  end

  # The reason a person can act on, from the database's own account of the refusal.
  def self.reason_for(exception)
    detail = exception.cause.respond_to?(:result) ? exception.cause.result&.error_field(PG::PG_DIAG_MESSAGE_DETAIL) : nil
    detail = detail.to_s.strip

    case exception
    when ActiveRecord::InvalidForeignKey
      if (table = detail[/still referenced from table "([^"]+)"/, 1])
        "This record is still in use by #{table.humanize(capitalize: false)}; move or remove those first."
      elsif (column, value, table = detail.match(/\AKey \(([^)]+)\)=\(([^)]*)\) is not present in table "([^"]+)"/)&.captures)
        "#{column.humanize} names #{value.inspect}, which no #{table.singularize.humanize(capitalize: false)} holds."
      else
        "That change would leave a record pointing at nothing."
      end
    else
      if (column, value = detail.match(/\AKey \(([^)]+)\)=\(([^)]*)\) already exists/)&.captures)
        "#{column.humanize} #{value.inspect} is already taken."
      else
        "That record already exists."
      end
    end
  end

  private

  def handle_constraint_violation(exception)
    reason = ConstraintViolationResponses.reason_for(exception)
    Rails.logger.warn("[constraint] #{exception.class}: #{reason}")

    if is_a?(ActionController::API)
      render json: { error: reason, error_code: "CONSTRAINT_VIOLATION" }, status: :unprocessable_entity
    else
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: reason }
        format.json { render json: { error: reason, error_code: "CONSTRAINT_VIOLATION" }, status: :unprocessable_entity }
        format.any  { render plain: reason, status: :unprocessable_entity }
      end
    end
  end
end
