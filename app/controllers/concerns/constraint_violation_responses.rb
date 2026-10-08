# A write the database refuses (a foreign key, a unique index, a CHECK or a NOT
# NULL) answers 422 with the reason, never a 500: the slug columns carry foreign
# keys and the state columns carry CHECK constraints (StringStates), so a destroy
# that would strand children, a write naming a row that does not exist, a slug
# that is already taken, or a stage outside its list all reach here when no model
# validation caught them first.
#
# HTML goes back where it came from with the reason as the alert; JSON gets
# `{ error:, error_code: "CONSTRAINT_VIOLATION" }`. Every refusal but a taken slug
# (an expected one) is also an ErrorLog row: it is a race or a missing
# validation, and a 422 alone would hide it. A foreign-key refusal is not logged;
# the models validate those and a destroy with children is a normal answer.
# Include it after the StandardError catch-all, since rescue_from tries the last
# declaration first.
module ConstraintViolationResponses
  extend ActiveSupport::Concern

  REFUSALS = [
    ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotUnique,
    ActiveRecord::CheckViolation, ActiveRecord::NotNullViolation
  ].freeze
  ERROR_CODE = "CONSTRAINT_VIOLATION".freeze
  # Where the database's message starts quoting the refused row.
  ROW_ECHO = /\s*DETAIL:\s+Failing row contains.*/m

  included do
    rescue_from(*REFUSALS, with: :handle_constraint_violation)
  end

  def self.refusal?(exception) = REFUSALS.any? { |klass| exception.is_a?(klass) }

  # A database message without the row it quotes, for a site that renders a
  # rescued exception's own message.
  def self.without_row(message) = message.to_s.sub(ROW_ECHO, "")

  # One field of the database's error report, or "".
  def self.diagnostic(exception, field)
    value = exception.cause.respond_to?(:result) ? exception.cause.result&.error_field(field) : nil
    value.to_s.strip
  end

  # The database's own account of the refusal ("Key (slug)=(x) already exists.").
  def self.detail_for(exception)
    diagnostic(exception, PG::PG_DIAG_MESSAGE_DETAIL)
  end

  # True for a unique refusal on a record's own slug column.
  def self.slug_write?(exception)
    exception.is_a?(ActiveRecord::RecordNotUnique) && detail_for(exception).start_with?("Key (slug)=")
  end

  # True for a refusal worth an ErrorLog row: a validation was skipped or is missing.
  def self.unexpected?(exception)
    case exception
    when ActiveRecord::CheckViolation, ActiveRecord::NotNullViolation then true
    when ActiveRecord::RecordNotUnique then !slug_write?(exception)
    else false
    end
  end

  # A CHECK refusal, named from the constraint: the database's detail echoes the
  # whole row, so it is never shown.
  def self.check_reason(exception)
    name = diagnostic(exception, PG::PG_DIAG_CONSTRAINT_NAME)
    if (column = StringStates.for_constraint(name))
      "#{column.column.humanize} must be one of #{column.values.join(", ")}."
    elsif name.present?
      "That write breaks the rule #{name.humanize(capitalize: false).inspect}."
    else
      "That write breaks a rule the database enforces."
    end
  end

  def self.not_null_reason(exception)
    column = diagnostic(exception, PG::PG_DIAG_COLUMN_NAME)
    column.present? ? "#{column.humanize} cannot be blank." : "A required value is missing."
  end

  # The reason a person can act on, from the database's own account of the refusal.
  def self.reason_for(exception)
    detail = detail_for(exception)

    case exception
    when ActiveRecord::CheckViolation then check_reason(exception)
    when ActiveRecord::NotNullViolation then not_null_reason(exception)
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
    if ConstraintViolationResponses.unexpected?(exception) && !@_error_logged
      ErrorLog.capture!(exception)
      @_error_logged = true
    end

    if is_a?(ActionController::API)
      render json: { error: reason, error_code: ERROR_CODE }, status: :unprocessable_entity
    else
      respond_to do |format|
        format.html { redirect_back_or_to root_path, alert: reason }
        format.json { render json: { error: reason, error_code: ERROR_CODE }, status: :unprocessable_entity }
        format.any  { render plain: reason, status: :unprocessable_entity }
      end
    end
  end
end
