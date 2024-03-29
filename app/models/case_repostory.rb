class CaseRepostory < ActiveRecord::Base
  
  belongs_to :context, :polymorphic => true
  has_many :case_issues

  attr_accessible :context_id, :context_type, :name, :sub_type
  validates_presence_of :name

end
