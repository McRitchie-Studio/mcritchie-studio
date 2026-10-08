require "test_helper"
require "open3"

# [unit] DeadColumns: each listed column is still in its table and ignored by its
# model, and no code names one. A name another table also uses (queued_at,
# error_message, logo_url) cannot be told apart by a grep; ignoring it makes a
# reader raise, which the model assertions pin.
class DeadTaskColumnsGrepTest < ActiveSupport::TestCase
  DECLARATION = "app/models/concerns/dead_columns.rb".freeze
  SEARCHED = %w[app lib bin config db/seeds db/seeds.rb].freeze
  SHARED_NAMES = %w[queued_at error_message logo_url].freeze

  def model_for(table) = ApplicationRecord.descendants.find { |model| model.table_name == table } || table.classify.constantize

  def hits(name, paths)
    out, = Open3.capture2("git", "grep", "-nw", "-e", name, "--", *paths, chdir: Rails.root.to_s)
    out.lines.map(&:chomp)
  end

  test "[unit] each dead column is in its table and absent from its model" do
    DeadColumns::BY_TABLE.each do |table, columns|
      model = model_for(table)
      in_table = ActiveRecord::Base.connection.columns(table).map(&:name)

      assert_empty columns - in_table, "#{table}: DeadColumns names a column the table no longer has"
      assert_empty columns & model.column_names, "#{model} still loads a dead column"
      columns.each { |column| assert_not model.new.respond_to?(column), "#{model}##{column}" }
    end
    assert_includes Task.column_names, "stage", "control: a live column loads"
  end

  test "[unit] no code names a dead column" do
    names = DeadColumns::BY_TABLE.values.flatten - SHARED_NAMES

    assert_operator names.size, :>=, 9
    assert_empty names.flat_map { |name| hits(name, SEARCHED).reject { |line| line.start_with?("#{DECLARATION}:") } }
    assert_equal names.sort, names.select { |name| hits(name, [ DECLARATION ]).any? }.sort, "control: the grep finds a name where it is"
  end
end
