class AddStatusToLearningPlanUsers < ActiveRecord::Migration
  tag :predeploy

  def self.up
    add_column :learning_plan_users, :workflow_state, :string
  end

  def self.down
    remove_column :learning_plan_users, :workflow_state
  end
end
