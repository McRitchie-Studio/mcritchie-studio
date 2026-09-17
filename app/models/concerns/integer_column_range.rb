# Makes an integer-column overflow legible, and keeps it from vetoing a workflow.
#
# THE PROBLEM THIS EXISTS FOR (incident 2026-09-17). `ActiveModel::Type::Integer`
# range-checks at SERIALIZE time — inside the INSERT, not at assignment and not
# during validation — and the error it raises carries only the value and the byte
# width:
#
#   ActiveModel::RangeError: 2231911675 is out of range for
#     ActiveModel::Type::Integer with limit 4 bytes
#
# No table. No column. No record. That message reached an operator as a bare 422
# from `bin/task move <slug> archived` and cost most of a session to trace back to
# `task_events.cache_read_tokens`.
#
# This concern does two things, and they are deliberately separate:
#
#   1. NAMING (global, error path only). Included by ApplicationRecord, so every
#      model gets it. On the way out of a failed save it finds the attribute that
#      is actually out of its column's range and re-raises OutOfRangeColumnError
#      with the table and column named. The subclass keeps `ActiveModel::RangeError`
#      as its parent, so every existing `rescue ActiveModel::RangeError` and
#      `rescue RangeError` still catches it — the only thing that changes is that
#      the message is now actionable. There is no happy-path work beyond one
#      `yield`.
#
#   2. CLAMPING (opt-in, per model). `clamps_integer_columns` declares that a
#      column carries TELEMETRY — a token count, a cost counter — and that no
#      value of it may ever abort the write it rides along with. The incident was
#      not "telemetry failed to record"; it was "the task did not archive",
#      because Task#record_transition_event runs `after_update` INSIDE the task's
#      save transaction (app/models/task.rb:531). A number nothing depends on for
#      correctness must never be able to roll back a stage change.
#
# The ceiling is read from the COLUMN, never hardcoded, so the guard tracks the
# schema: it is correct before the bigint migration, after it, and after any
# future width change, with no second place to keep in sync.
module IntegerColumnRange
  extend ActiveSupport::Concern

  # Raised in place of a bare ActiveModel::RangeError, naming the column.
  class OutOfRangeColumnError < ActiveModel::RangeError
    attr_reader :record, :attribute, :value, :byte_limit

    def initialize(record:, attribute:, value:, byte_limit:, cause_message: nil)
      @record = record
      @attribute = attribute
      @value = value
      @byte_limit = byte_limit
      super(build_message(cause_message))
    end

    private

    def build_message(cause_message)
      min, max = IntegerColumnRange.range_for_bytes(byte_limit)
      message = "#{record.class.table_name}.#{attribute} cannot store #{value} — " \
                "it is a #{byte_limit}-byte integer column (range #{min}..#{max}). " \
                "Widen the column to bigint, or clamp the value at the write path."
      message += " (#{cause_message})" if cause_message.present?
      message
    end
  end

  # Signed two's-complement bounds for a column of `bytes` bytes.
  def self.range_for_bytes(bytes)
    bits = (bytes || 4) * 8
    limit = 1 << (bits - 1)
    [-limit, limit - 1]
  end

  included do
    # Error path only: the block is the save itself, so the happy path pays for
    # one yield and nothing else.
    around_save :name_out_of_range_column
  end

  class_methods do
    # Declare telemetry columns: values too wide for the column are clamped to
    # what it can hold rather than aborting the save. Every clamp writes an
    # ErrorLog naming the column, the raw value and the ceiling, so a clamp is
    # loud — it degrades the number, never the workflow, and never silently.
    def clamps_integer_columns(*names)
      clamped = names.map(&:to_s).freeze
      define_method(:clamped_integer_columns) { clamped }
      before_save :clamp_integer_columns
    end
  end

  private

  def name_out_of_range_column
    yield
  rescue OutOfRangeColumnError
    # Already named — a nested record (a TaskEvent written from Task's
    # after_update callback) raised it and this is the outer save seeing it go by.
    raise
  rescue ActiveModel::RangeError => e
    offender = first_out_of_range_attribute
    raise e unless offender

    attribute, value, byte_limit = offender
    raise OutOfRangeColumnError.new(
      record: self, attribute: attribute, value: value,
      byte_limit: byte_limit, cause_message: e.message
    )
  end

  # The raised error carries no attribute, but we hold the record — so ask it.
  def first_out_of_range_attribute
    self.class.columns_hash.each do |name, column|
      next unless column.type == :integer

      value = self[name]
      next unless value.is_a?(Integer)

      min, max = IntegerColumnRange.range_for_bytes(column.limit)
      next if value.between?(min, max)

      return [name, value, column.limit || 4]
    end
    nil
  end

  def clamp_integer_columns
    clamped_integer_columns.each do |name|
      column = self.class.columns_hash[name]
      next unless column&.type == :integer

      raw = self[name]
      next unless raw.is_a?(Integer)

      min, max = IntegerColumnRange.range_for_bytes(column.limit)
      next if raw.between?(min, max)

      self[name] = raw.clamp(min, max)
      log_clamp(name, raw, column.limit)
    end
  end

  def log_clamp(name, raw, byte_limit)
    ErrorLog.capture!(
      OutOfRangeColumnError.new(
        record: self, attribute: name, value: raw, byte_limit: byte_limit,
        cause_message: "clamped to #{self[name]} so the write could proceed"
      )
    )
  rescue StandardError => e
    # The whole point of the clamp is that telemetry cannot veto a write, so
    # failing to LOG the clamp must not veto it either.
    Rails.logger.warn("[IntegerColumnRange] could not log clamp of #{name}: #{e.class}: #{e.message}")
  end
end
