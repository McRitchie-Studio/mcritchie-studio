class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Turn a bare "2231911675 is out of range for ActiveModel::Type::Integer with
  # limit 4 bytes" into one that names the table and column. Error path only —
  # see app/models/concerns/integer_column_range.rb.
  include IntegerColumnRange
end
