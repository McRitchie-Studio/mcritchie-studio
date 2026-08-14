# frozen_string_literal: true

require "test_helper"

# [unit] The standard Studio user profile columns, as they landed in THIS app.
#
# They are defined once in studio-engine (0.46.0) and installed here through
# `bin/rails studio_engine:install:migrations`. This file is the app-side proof
# that the install actually happened and produced the agreed types — the thing a
# shared standard is worthless without.
#
# The columns exist here whether or not this app reads them yet, by design: an
# app should never have to invent its own spelling for the same fact later.
class StandardProfileColumnsTest < ActiveSupport::TestCase
  STANDARD = {
    "first_name"   => :string,
    "birth_day"    => :integer,
    "birth_month"  => :integer,
    "birth_year"   => :integer,
    "ip_locations" => :jsonb
  }.freeze

  test "every standard profile column exists with the agreed type" do
    STANDARD.each do |name, type|
      column = User.columns_hash[name]

      assert column, "users.#{name} is missing — run studio_engine:install:migrations && db:migrate"
      assert_equal type, column.type, "users.#{name} should be #{type}"
    end
  end

  test "ip_locations is an empty list, never null" do
    # It is appended to, so a null would mean every writer needs a nil guard and
    # the first write on a row would be a special case.
    column = User.columns_hash["ip_locations"]

    assert_equal false, column.null, "ip_locations must be NOT NULL"
    assert_equal [], User.new.ip_locations, "a fresh user starts with an empty list"
  end

  test "the birth trio is three integers rather than one date" do
    # Deliberate: age needs the year plus month/day for the boundary case, and
    # "whose birthday is today" needs month + day and no year at all. No single
    # date-of-birth column is stored.
    assert_nil User.columns_hash["date_of_birth"],
      "the standard is the birth_day/birth_month/birth_year trio"
  end

  test "a first name can be written and read back" do
    user = users(:viewer)
    user.update_columns(first_name: "Alex")

    assert_equal "Alex", user.reload.first_name
  end
end
