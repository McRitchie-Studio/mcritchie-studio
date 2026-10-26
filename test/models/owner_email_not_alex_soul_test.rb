require "test_helper"
require Rails.root.join("bin/lib/merge_permission").to_s
require Rails.root.join("bin/lib/merge_permit_cli").to_s

# [unit] Since ritch-renamed-alex the persona soul is slugged `alex`, which is the
# local part of Alex McRitchie's own mailbox. Every reader that turns an email
# into a soul reads alex@mcritchie.studio as the HUMAN, never the agent, while a
# real agent address still names its soul.
class OwnerEmailNotAlexSoulTest < ActiveSupport::TestCase
  include StageAgentsHelper

  test "the owner's addresses are the owner's, any case" do
    assert AgentPerson.owner_email?("alex@mcritchie.studio")
    assert AgentPerson.owner_email?(" Alex@McRitchie.Studio ")
    refute AgentPerson.owner_email?("ray@mcritchie.studio")
    refute AgentPerson.owner_email?(nil)
  end

  test "a commit from the owner's mailbox names no soul; an agent's still does" do
    assert_nil Github::TaskDerivation.soul_from_email("alex@mcritchie.studio")
    assert_equal "carl", Github::TaskDerivation.soul_from_email("carl@mcritchie.studio")
    assert_equal "alex", Github::TaskDerivation.soul_from_email("ray@mcritchie.studio"), "the seat's old address"
  end

  test "a task event acted by the owner's email resolves to no agent" do
    agents = Agent.all.index_by(&:slug)
    assert_nil resolve_actor_agent("alex@mcritchie.studio", agents)
    assert_equal agents["alex"], resolve_actor_agent("alex", agents), "the bare slug is the persona"
  end

  test "merge-permit reads no author from an owner commit trailer" do
    text = "Fix\n\nCo-Authored-By: Alex McRitchie <alex@mcritchie.studio>\nCo-Authored-By: Carl <carl@mcritchie.studio>"
    derived = text.gsub(MergePermitCli::OWNER_EMAIL, "").scan(MergePermitCli::SOUL_EMAIL).flatten
    assert_equal %w[carl], derived
  end
end
