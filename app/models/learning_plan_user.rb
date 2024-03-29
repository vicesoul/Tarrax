class LearningPlanUser < ActiveRecord::Base
  include Workflow

  attr_accessible :learning_plan, :user_id, :role_name, :status
  validates_presence_of :user

  belongs_to :learning_plan
  belongs_to :user

  named_scope :of_enrolled, {
    :conditions => ["workflow_state = ?", 'enrolled']
  }

  named_scope :of_enrolled_including_partial, {
    :conditions => ["workflow_state IN (?)", ['enrolled', 'partial'] ]
  }

  workflow do
    state :initial do
      event :enroll, :transitions_to => :enrolled
      event :part_enroll, :transitions_to => :partial
    end

    state :enrolled do
      event :revert, :transitions_to => :reverted
    end

    state :partial do
      event :revert, :transitions_to => :reverted
    end

    state :reverted do
      event :enroll, :transitions_to => :enrolled
      event :part_enroll, :transitions_to => :partial
    end
  end

  def states
    {
      'initial'  => t('states.initial', "Initial"),
      'enrolled' => t('states.enrolled', "Enrolled"),
      'partial'  => t('states.partial', "Partial"),
      'reverted' => t('states.reverted', "reverted")
    }
  end

  def display_workflow_state
    states[workflow_state]
  end

  def enrollable?
    %w(initial reverted).include? workflow_state
  end

  def revertable?
    %w(enrolled partial).include? workflow_state
  end
end
