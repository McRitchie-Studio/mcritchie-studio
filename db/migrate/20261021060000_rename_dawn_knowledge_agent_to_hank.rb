# The Commercial Welding business agent "Dawn" is renamed "Hank" (Alex,
# 2026-10-20): the name collided with Dawn, the seller, in every deal
# conversation. Every knowledge-layer access map in the hub is keyed by agent
# slug, so each row's "dawn" key moves to "hank" with its level unchanged. The
# sibling migration in mcritchie-industries does the same for its own table.
#
# ORDER IS SAFE EITHER WAY. A missing key reads as "none" (Studio::KnowledgeDoc
# #access_for), so between the code deploy and this migration a privileged row
# hides from Hank rather than showing to anyone.
#
# A row that already carries "hank" keeps it: the existing key sits on the right
# of the concatenation, and jsonb || lets the right side win.
class RenameDawnKnowledgeAgentToHank < ActiveRecord::Migration[8.1]
  TABLES = %w[studio_knowledge_docs communications knowledge_sources source_documents].freeze

  def up
    TABLES.each { |table| rename_key(table, "dawn", "hank") }
  end

  def down
    TABLES.each { |table| rename_key(table, "hank", "dawn") }
  end

  private

  def rename_key(table, from, to)
    execute <<~SQL
      UPDATE #{quote_table_name(table)}
      SET access = jsonb_build_object(#{quote(to)}, access -> #{quote(from)}) || (access - #{quote(from)})
      WHERE access ? #{quote(from)}
    SQL
  end

  def quote(value) = connection.quote(value)
end
