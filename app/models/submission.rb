#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Submission < ActiveRecord::Base
  include SendToStream
  attr_protected :submitted_at
  attr_readonly :assignment_id
  belongs_to :attachment # this refers to the screenshot of the submission if it is a url submission
  belongs_to :assignment
  belongs_to :user
  belongs_to :grader, :class_name => 'User'
  belongs_to :group
  belongs_to :media_object
  belongs_to :student, :class_name => 'User', :foreign_key => :user_id
  has_many :submission_comments, :order => 'created_at', :dependent => :destroy
  has_many :visible_submission_comments, :class_name => 'SubmissionComment', :order => 'created_at, id', :conditions => { :hidden => false }
  has_many :hidden_submission_comments, :class_name => 'SubmissionComment', :order => 'created_at, id', :conditions => { :hidden => true }
  has_many :assessment_requests, :as => :asset
  has_many :assigned_assessments, :class_name => 'AssessmentRequest', :as => :assessor_asset
  belongs_to :quiz_submission
  has_one :rubric_assessment, :as => :artifact, :conditions => {:assessment_type => "grading"}
  has_many :rubric_assessments, :as => :artifact
  has_many :attachment_associations, :as => :context
  has_many :attachments, :through => :attachment_associations
  has_many :conversation_messages, :as => :asset # one message per private conversation
  has_many :content_participations, :as => :content

  serialize :turnitin_data, Hash
  validates_presence_of :assignment_id, :user_id
  validates_length_of :body, :maximum => maximum_long_text_length, :allow_nil => true, :allow_blank => true
  include CustomValidations
  validates_as_url :url

  named_scope :with_comments, :include => [:submission_comments ]
  named_scope :after, lambda{|date|
    {:conditions => ['submissions.created_at > ?', date] }
  }
  named_scope :before, lambda{|date|
    {:conditions => ['submissions.created_at < ?', date]}
  }
  named_scope :submitted_before, lambda{|date|
    {:conditions => ['submitted_at < ?', date] }
  }
  named_scope :submitted_after, lambda{|date|
    {:conditions => ['submitted_at > ?', date] }
  }

  named_scope :for_context_codes, lambda { |context_codes|
    { :conditions => {:context_code => context_codes} }
  }

  # This should only be used in the course drop down to show assignments recently graded.
  named_scope :recently_graded_assignments, lambda{|user_id, date, limit|
    {
            :select => 'assignments.id, assignments.title, assignments.points_possible, assignments.due_at,
                        submissions.grade, submissions.score, submissions.graded_at, assignments.grading_type,
                        assignments.context_id, assignments.context_type, courses.name AS context_name',
            :joins => 'JOIN assignments ON assignments.id = submissions.assignment_id
                       JOIN courses ON courses.id = assignments.context_id',
            :conditions => ["graded_at > ? AND user_id = ? AND muted = ?", date.to_s(:db), user_id, false],
            :order => 'graded_at DESC',
            :limit => limit
            }
  }

  named_scope :needs_grading, :conditions => <<-SQL
    submissions.submission_type IS NOT NULL 
    AND (submissions.workflow_state = 'pending_review'
      OR (submissions.workflow_state = 'submitted' 
        AND (submissions.score IS NULL OR NOT submissions.grade_matches_current_submission)
      )
    )
  SQL

  named_scope :for_course, lambda{ |course|
    { :conditions => ["submissions.assignment_id IN (SELECT assignments.id FROM assignments WHERE assignments.context_id = ? AND assignments.context_type = 'Course')", course.id] }
  }

  def self.needs_grading_conditions(prefix = nil)
    conditions = needs_grading.proxy_options[:conditions].gsub(/\s+/, ' ')
    conditions.gsub!("submissions.", prefix + ".") if prefix
    conditions
  end


  sanitize_field :body, Instructure::SanitizeField::SANITIZE

  attr_accessor :saved_by
  before_save :update_if_pending
  before_save :validate_single_submission, :validate_enrollment, :infer_values, :set_context_code
  before_save :prep_for_submitting_to_turnitin
  before_save :check_url_changed
  after_save :touch_user
  after_save :update_assignment
  after_save :update_attachment_associations
  after_save :submit_attachments_to_crocodoc
  after_save :queue_websnap
  after_save :update_final_score
  after_save :submit_to_turnitin_later
  after_save :update_admins_if_just_submitted
  after_save :check_for_media_object
  after_save :update_quiz_submission
  after_save :update_participation

  def self.needs_grading_trigger_sql
    # every database uses a different construct for a current UTC timestamp...
    default_sql = <<-SQL
      UPDATE assignments
      SET needs_grading_count = needs_grading_count + %s, updated_at = {{now}}
      WHERE id = NEW.assignment_id
      AND context_type = 'Course'
      AND #{Enrollment.active_student_subselect("user_id = NEW.user_id AND course_id = assignments.context_id")};
      SQL

    { :default    => default_sql.gsub("{{now}}", "now()"),
      :postgresql => default_sql.gsub("{{now}}", "now() AT TIME ZONE 'UTC'"),
      :sqlite     => default_sql.gsub("{{now}}", "datetime('now')"),
      :mysql      => default_sql.gsub("{{now}}", "utc_timestamp()") }
  end

  trigger.after(:insert) do |t|
    t.where("#{needs_grading_conditions("NEW")}") do
      Hash[needs_grading_trigger_sql.map{|key, value| [key, value % 1]}]
    end
  end

  trigger.after(:update) do |t|
    t.where("(#{needs_grading_conditions("NEW")}) <> (#{needs_grading_conditions("OLD")})") do
      Hash[needs_grading_trigger_sql.map{|key, value| [key, value % "CASE WHEN (#{needs_grading_conditions('NEW')}) THEN 1 ELSE -1 END"]}]
    end
  end
  
  attr_reader :suppress_broadcast
  attr_reader :group_broadcast_submission


  has_a_broadcast_policy

  simply_versioned :explicit => true
  
  set_policy do
    given {|user| user && user.id == self.user_id }
    can :read and can :comment and can :make_group_comment and can :submit

    given { |user| user && user.id == self.user_id && !self.assignment.muted? }
    can :read_grade

    given {|user| self.assignment && self.assignment.context && user && self.user &&
      self.assignment.context.observer_enrollments.find_by_user_id_and_associated_user_id_and_workflow_state(user.id, self.user.id, 'active') }
    can :read and can :read_comments

    given {|user| self.assignment && !self.assignment.muted? && self.assignment.context && user && self.user &&
      self.assignment.context.observer_enrollments.find_by_user_id_and_associated_user_id_and_workflow_state(user.id, self.user.id, 'active').try(:grants_right?, user, :read_grades) }
    can :read_grade

    given {|user, session| self.assignment.cached_context_grants_right?(user, session, :manage_grades) }#admins.include?(user) }
    can :read and can :comment and can :make_group_comment and can :read_grade and can :grade

    given {|user, session| self.assignment.cached_context_grants_right?(user, session, :view_all_grades) }
    can :read and can :read_grade

    given {|user| user && self.assessment_requests.map{|a| a.assessor_id}.include?(user.id) }
    can :read and can :comment

    given { |user, session|
      grants_right?(user, session, :read_grade) &&
      turnitin_data &&
      (assignment.cached_context_grants_right?(user, session, :manage_grades) ||
        case assignment.turnitin_settings[:originality_report_visibility]
          when 'immediate'; true
          when 'after_grading'; current_submission_graded?
          when 'after_due_date'; assignment.due_at && assignment.due_at < Time.now.utc
        end
      )
    }
    can :view_turnitin_report
  end
  
  on_update_send_to_streams do
    if self.graded_at && self.graded_at > 5.minutes.ago && !@already_sent_to_stream
      @already_sent_to_stream = true
      self.user_id
    end
  end
  
  def update_final_score
    if @score_changed
      connection.after_transaction_commit { Enrollment.send_later_if_production(:recompute_final_score, self.user_id, self.context.id) }
      self.assignment.send_later_if_production(:multiple_module_actions, [self.user_id], :scored, self.score) if self.assignment
    end
    true
  end
  
  def update_quiz_submission
    return true if @saved_by == :quiz_submission || !self.quiz_submission || self.score == self.quiz_submission.kept_score
    self.quiz_submission.set_final_score(self.score)
    true
  end
  
  def url
    read_body = read_attribute(:body) && CGI::unescapeHTML(read_attribute(:body))
    if read_body && read_attribute(:url) && read_body[0..250] == read_attribute(:url)[0..250]
      @full_url = read_attribute(:body)
    else
      @full_url = read_attribute(:url)
    end
  end

  def plaintext_body
    self.extend TextHelper
    strip_tags((self.body || "").gsub(/\<\s*br\s*\/\>/, "\n<br/>").gsub(/\<\/p\>/, "</p>\n"))
  end
  
  def check_turnitin_status(attempt=1)
    self.turnitin_data ||= {}
    turnitin = nil
    needs_retry = false

    # check all assets in the turnitin_data (self.turnitin_assets is only the
    # current assets) so that we get the status for assets of previous versions
    # of the submission as well
    self.turnitin_data.keys.each do |asset_string|
      data = self.turnitin_data[asset_string]
      next unless data && data.is_a?(Hash) && data[:object_id]
      if data[:similarity_score].blank?
        if attempt < TURNITIN_RETRY
          turnitin ||= Turnitin::Client.new(*self.context.turnitin_settings)
          res = turnitin.generateReport(self, asset_string)
          if res[:similarity_score]
            data[:similarity_score] = res[:similarity_score].to_f
            data[:web_overlap] = res[:web_overlap].to_f
            data[:publication_overlap] = res[:publication_overlap].to_f
            data[:student_overlap] = res[:student_overlap].to_f
            data[:state] = 'failure'
            data[:state] = 'problem' if data[:similarity_score] < 75
            data[:state] = 'warning' if data[:similarity_score] < 50
            data[:state] = 'acceptable' if data[:similarity_score] < 25
            data[:state] = 'none' if data[:similarity_score] == 0
            data[:status] = 'scored'
          else
            needs_retry ||= true
          end
        else
          data[:status] = 'error'
        end
      else
        data[:status] = 'scored'
      end
      self.turnitin_data[asset_string] = data
    end

    send_at((5 * attempt).minutes.from_now, :check_turnitin_status, attempt + 1) if needs_retry
    self.turnitin_data_changed!
    self.save
  end
  
  def turnitin_report_url(asset_string, user)
    if self.turnitin_data && self.turnitin_data[asset_string] && self.turnitin_data[asset_string][:similarity_score]
      turnitin = Turnitin::Client.new(*self.context.turnitin_settings)
      self.send_later(:check_turnitin_status)
      if self.grants_right?(user, nil, :grade)
        turnitin.submissionReportUrl(self, asset_string)
      elsif self.grants_right?(user, nil, :view_turnitin_report)
        turnitin.submissionStudentReportUrl(self, asset_string)
      end
    else
      nil
    end
  end
  
  def prep_for_submitting_to_turnitin
    last_attempt = self.turnitin_data && self.turnitin_data[:last_processed_attempt]
    @submit_to_turnitin = false
    if self.turnitinable? && (!last_attempt || last_attempt < self.attempt)
      self.turnitin_data ||= {}
      if self.turnitin_data[:last_processed_attempt] != self.attempt
        self.turnitin_data[:last_processed_attempt] = self.attempt
      end
      @submit_to_turnitin = true
    end
  end

  TURNITIN_JOB_OPTS = { :n_strand => 'turnitin', :priority => Delayed::LOW_PRIORITY, :max_attempts => 2 }

  def submit_to_turnitin_later
    if self.turnitinable? && @submit_to_turnitin
      delay = Setting.get_cached('turnitin_submission_delay_seconds', 60.to_s).to_i
      send_later_enqueue_args(:submit_to_turnitin, { :run_at => delay.seconds.from_now }.merge(TURNITIN_JOB_OPTS))
    end
  end

  TURNITIN_RETRY = 5
  def submit_to_turnitin(attempt=0)
    return unless self.context.turnitin_settings
    turnitin = Turnitin::Client.new(*self.context.turnitin_settings)
    reset_turnitin_assets

    # Make sure the assignment exists and user is enrolled
    assign_status = self.assignment.create_in_turnitin
    enroll_status = turnitin.enrollStudent(self.context, self.user)
    unless assign_status && enroll_status
      if attempt < TURNITIN_RETRY
        send_later_enqueue_args(:submit_to_turnitin, { :run_at => 5.minutes.from_now }.merge(TURNITIN_JOB_OPTS), attempt + 1)
      else
        assign_error = self.assignment.turnitin_settings[:error]
        turnitin_assets.each do |a| 
          self.turnitin_data[a.asset_string][:status] = 'error'
          self.turnitin_data[a.asset_string].merge!(assign_error) if assign_error.present?
        end
        self.turnitin_data_changed!
        self.save
      end
      return false
    end

    # Submit the file(s)
    submission_response = turnitin.submitPaper(self)
    submission_response.each do |res_asset_string, response|
      self.turnitin_data[res_asset_string].merge!(response)
      self.turnitin_data_changed!
      if !response[:object_id] && !(attempt < TURNITIN_RETRY)
        self.turnitin_data[res_asset_string][:status] = 'error'
      end
    end

    send_later_enqueue_args(:check_turnitin_status, { :run_at => 5.minutes.from_now }.merge(TURNITIN_JOB_OPTS))
    self.save

    # Schedule retry if there were failures
    submit_status = submission_response.present? && submission_response.values.all?{ |v| v[:object_id] }
    unless submit_status
      send_later_enqueue_args(:submit_to_turnitin, { :run_at => 5.minutes.from_now }.merge(TURNITIN_JOB_OPTS), attempt + 1) if attempt < TURNITIN_RETRY
      return false
    end

    true
  end

  def turnitin_assets
    if self.submission_type == 'online_upload'
      self.attachments.select{ |a| a.turnitinable? }
    elsif self.submission_type == 'online_text_entry'
      [self]
    end
  end

  def reset_turnitin_assets
    self.turnitin_data ||= {}
    turnitin_assets.each do |a|
      asset_data = self.turnitin_data[a.asset_string] || {}
      asset_data[:status] = 'pending'
      [:error_code, :error_message, :public_error_message].each do |key|
        asset_data.delete(key)
      end
      self.turnitin_data[a.asset_string] = asset_data
      self.turnitin_data_changed!
    end
  end

  def resubmit_to_turnitin
    reset_turnitin_assets
    self.save

    @submit_to_turnitin = true
    submit_to_turnitin_later
  end

  def turnitinable?
    if self.submission_type == 'online_upload' || self.submission_type == 'online_text_entry'
      if self.assignment.turnitin_enabled?
        return true
      end
    end
    false
  end

  def update_assignment
    self.send_later(:context_module_action)
    true
  end
  protected :update_assignment
  
  def context_module_action
    if self.assignment && self.user
      if self.score
        self.assignment.context_module_action(self.user, :scored, self.score)
      elsif self.submitted_at
        self.assignment.context_module_action(self.user, :submitted)
      end
    end
  end
  
  # If an object is pulled from a simply_versioned yaml it may not have a submitted at. 
  # submitted_at is needed by the SpeedGrader, so it is set to the updated_at value
  def submitted_at
    if submission_type
      if not read_attribute(:submitted_at)
        write_attribute(:submitted_at, read_attribute(:updated_at))
      end
      read_attribute(:submitted_at).in_time_zone rescue nil
    else
      nil
    end
  end
  
  def update_attachment_associations
    associations = self.attachment_associations
    association_ids = associations.map(&:attachment_id)
    ids = (Array(self.attachment_ids || "").join(',')).split(",").map{|id| id.to_i}
    ids << self.attachment_id if self.attachment_id
    ids.uniq!
    existing_associations = associations.select{|a| ids.include?(a.attachment_id) }
    (associations - existing_associations).each{|a| a.destroy }
    unassociated_ids = ids.reject{|id| association_ids.include?(id) }
    return if unassociated_ids.empty?
    attachments = Attachment.find_all_by_id(unassociated_ids)
    attachments.each do |a|
      if((a.context_type == 'User' && a.context_id == user_id) ||
          (a.context_type == 'Group' && a.context_id == group_id) ||
          (a.context_type == 'Assignment' && a.context_id == assignment_id && a.available?))
        aa = self.attachment_associations.find_by_attachment_id(a.id)
        aa ||= self.attachment_associations.create(:attachment => a)
      end
    end
  end

  def submit_attachments_to_crocodoc
    if attachment_ids_changed?
      attachments = attachment_associations.map(&:attachment)
      attachments.each do |a|
        a.send_later_enqueue_args :submit_to_crocodoc,
          :n_strand     => 'crocodoc',
          :max_attempts => 1,
          :priority => Delayed::LOW_PRIORITY
      end
    end
  end

  def set_context_code
    self.context_code = self.assignment.context_code rescue nil
  end

  def infer_values
    if self.assignment
      self.score = self.assignment.max_score if self.assignment.max_score && self.score && self.score > self.assignment.max_score
      self.score = self.assignment.min_score if self.assignment.min_score && self.score && self.score < self.assignment.min_score 
    end
    self.submitted_at ||= Time.now if self.has_submission? || (self.submission_type && !self.submission_type.empty?)
    self.quiz_submission.reload if self.quiz_submission
    self.workflow_state = 'unsubmitted' if self.submitted? && !self.has_submission?
    self.workflow_state = 'graded' if self.grade && self.score && self.grade_matches_current_submission
    self.workflow_state = 'pending_review' if self.submission_type == 'online_quiz' && self.quiz_submission && !self.quiz_submission.complete?
    if self.graded? && self.graded_at_changed? && self.assignment.available?
      self.changed_since_publish = true
    end
    if self.workflow_state_changed? && self.graded?
      self.graded_at = Time.now
    end
    self.media_comment_id = nil if self.media_comment_id && self.media_comment_id.strip.empty?
    if self.media_comment_id && (self.media_comment_id_changed? || !self.media_object_id)
      mo = MediaObject.by_media_id(self.media_comment_id).first
      self.media_object_id = mo && mo.id
    end
    self.media_comment_type = nil unless self.media_comment_id
    if self.submitted_at
      self.attempt ||= 0
      self.attempt += 1 if self.submitted_at_changed?
      self.attempt = 1 if self.attempt < 1
      compute_lateness if late.nil? || self.submitted_at_changed?
    end
    if self.submission_type == 'media_recording' && !self.media_comment_id
      raise "Can't create media submission without media object"
    end
    if self.submission_type == 'online_quiz'
      self.quiz_submission ||= QuizSubmission.find_by_submission_id(self.id) rescue nil
      self.quiz_submission ||= QuizSubmission.find_by_user_id_and_quiz_id(self.user_id, self.assignment.quiz.id) rescue nil
    end
    @just_submitted = self.submitted? && self.submission_type && (self.new_record? || self.workflow_state_changed?)
    if self.score_changed?
      @score_changed = true
      if self.assignment
        self.grade = self.assignment.score_to_grade(self.score, self.grade)
      else
        self.grade = self.score.to_s
      end
    end
    
    self.process_attempts ||= 0
    self.grade = nil if !self.score
    # I think the idea of having unpublished scores is unnecessarily confusing.
    # It may be that we want to have that functionality later on, but for now
    # I say it's just confusing.
    if true #self.assignment && self.assignment.published?
      self.published_score = self.score
      self.published_grade = self.grade
    end
    true
  end

  def update_admins_if_just_submitted
    if @just_submitted
      context.send_later_if_production(:resubmission_for, assignment)
    end
    true
  end

  def check_for_media_object
    if self.media_comment_id.present? && self.media_comment_id_changed?
      MediaObject.ensure_media_object(self.media_comment_id, {
        :user => self.user,
        :context => self.user,
      })
    end
  end
  
  def submission_history
    res = []
    last_submitted_at = nil
    self.versions.sort_by(&:created_at).reverse.each do |version|
      model = version.model
      if model.submitted_at && last_submitted_at.to_i != model.submitted_at.to_i
        res << model
        last_submitted_at = model.submitted_at
      end
    end
    res = self.versions.to_a[0,1].map(&:model) if res.empty?
    res.sort_by{ |s| s.submitted_at || Time.parse("Jan 1 2000") }
  end
  
  def check_url_changed
    @url_changed = self.url && self.url_changed?
    true
  end

  def queue_websnap
    if !self.attachment_id && @url_changed && self.url && self.submission_type == 'online_url'
      self.send_later_enqueue_args(:get_web_snapshot, { :priority => Delayed::LOW_PRIORITY })
    end
  end

  def attachment_ids
    read_attribute(:attachment_ids)
  end

  def versioned_attachments
    ids = (self.attachment_ids || "").split(",").map{|id| id.to_i}
    ids << self.attachment_id if self.attachment_id
    return [] if ids.empty?
    Attachment.find_all_by_id(ids).select{|a|
      (a.context_type == 'User' && a.context_id == user_id) || 
      (a.context_type == 'Group' && a.context_id == group_id) ||
      (a.context_type == 'Assignment' && a.context_id == assignment_id && a.available?)
    }
  end
  memoize :versioned_attachments
  
  def <=>(other)
    self.updated_at <=> other.updated_at
  end

  # Submission:
  #   Online submission submitted AFTER the due date (notify the teacher) - "Grade Changes"
  #   Submission graded (or published) - "Grade Changes"
  #   Grade changed - "Grade Changes"
  set_broadcast_policy do |p|
    p.dispatch :assignment_submitted_late
    p.to { assignment.context.instructors_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      !record.group_broadcast_submission and
      record.assignment.context.state == :available and 
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted) || record.prior_version.try(:submitted_at) != record.submitted_at) and
      record.state == :submitted and
      record.has_submission? and 
      record.late?
    }

    p.dispatch :assignment_submitted
    p.to { assignment.context.instructors_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.assignment.context.state == :available and
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted)) and
      record.state == :submitted and
      record.has_submission? and
      # don't send a submitted message because we already sent an :assignment_submitted_late message
      !record.late?
    }

    p.dispatch :assignment_resubmitted
    p.to { assignment.context.instructors_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.assignment.context.state == :available and
      record.submitted? and
      record.prior_version.submitted_at and
      record.prior_version.submitted_at != record.submitted_at and
      record.has_submission? and
      # don't send a resubmitted message because we already sent a :assignment_submitted_late message.
      !record.late?
    }

    p.dispatch :group_assignment_submitted_late
    p.to { assignment.context.instructors_in_charge_of(user_id) }
    p.whenever {|record| 
      !record.suppress_broadcast and
      record.group_broadcast_submission and
      record.assignment.context.state == :available and 
      ((record.just_created && record.submitted?) || record.changed_state_to(:submitted) || record.prior_version.try(:submitted_at) != record.submitted_at) and
      record.state == :submitted and
      record.late?
    }

    p.dispatch :submission_graded
    p.to { student }
    p.whenever {|record|
      !record.suppress_broadcast and
      !record.assignment.muted? and
      record.assignment.context.state == :available and
      record.assignment.state == :published and
      record.user.student_enrollments.map(&:course_id).include?(record.assignment.context_id) and
      (record.changed_state_to(:graded) || (record.changed_in_state(:graded, :fields => [:score, :grade]) && !@assignment_just_published && record.assignment_graded_in_the_last_hour?))
    }
    
    p.dispatch :submission_grade_changed
    p.to { student }
    p.whenever {|record|
      !record.suppress_broadcast and
      !record.assignment.muted? and
      record.graded_at and 
      record.assignment.context.state == :available and 
      record.assignment.state == :published and 
      (!record.assignment_graded_in_the_last_hour? or record.submission_type == 'online_quiz' ) and
      (@assignment_just_published || (record.changed_in_state(:graded, :fields => [:score, :grade]) && !record.assignment_graded_in_the_last_hour?))
    }

  end
  
  def assignment_graded_in_the_last_hour?
    self.prior_version && self.prior_version.graded_at && self.prior_version.graded_at > 1.hour.ago
  end
  
  def assignment_just_published!
    @assignment_just_published = true
    self.changed_since_publish = false
    self.save!
    @assignment_just_published = false
  end
  
  def changed_since_publish?
    self.changed_since_publish
  end
  
  def teacher
    @teacher ||= self.assignment.teacher_enrollment.user
  end

  def update_if_pending
    @attachments = nil
    if self.submission_type == 'online_quiz' && self.quiz_submission && self.score && self.score == self.quiz_submission.score
      self.workflow_state = self.quiz_submission.complete? ? 'graded' : 'pending_review'
    end
    true
  end

  def attachment_ids=(ids)
    write_attribute(:attachment_ids, ids)
  end
#   def attachment_ids=(ids)
    # raise "Cannot set attachment id's directly"
  # end

  def attachments=(attachments)
    # Accept attachments that were already approved, those that were just created
    # or those that were part of some outside context.  This is all to prevent
    # one student from sneakily getting access to files in another user's comments,
    # since they're all being held on the assignment for now.
    attachments ||= []
    old_ids = (Array(self.attachment_ids || "").join(",")).split(",").map{|id| id.to_i}
    write_attribute(:attachment_ids, attachments.select{|a| a && a.id && old_ids.include?(a.id) || (a.recently_created? && a.context == self.assignment) || a.context != self.assignment }.map{|a| a.id}.join(","))
  end

  def validate_single_submission
    @full_url = nil
    if read_attribute(:url) && read_attribute(:url).length > 250
      self.body = read_attribute(:url)
      self.url = read_attribute(:url)[0..250]
    end
    self.submission_type ||= "online_url" if self.url
    self.submission_type ||= "online_text_entry" if self.body
    self.submission_type ||= "online_upload" if !self.attachments.empty?
    true
  end
  private :validate_single_submission

  def validate_enrollment
    begin
      assignment.context.includes_student?(user)
      true
    rescue => e
      raise ArgumentError, "Cannot submit to an assignment when the student is not properly enrolled."
    end
  end
  private :validate_enrollment

  include Workflow

  workflow do
    state :submitted do
      event :grade_it, :transitions_to => :graded
    end
    state :unsubmitted
    state :pending_review
    state :graded
  end

  named_scope :graded, lambda {
    {:conditions => ['submissions.grade IS NOT NULL']}
  }

  named_scope :ungraded, lambda {
    {:conditions => ['submissions.grade IS NULL'], :include => :assignment}
  }

  named_scope :in_workflow_state, lambda { |provided_state|
    { :conditions => { :workflow_state => provided_state } }
  }

  named_scope :having_submission, :conditions => 'submissions.submission_type IS NOT NULL'

  named_scope :include_user, lambda {
    {:include => [:user] }
  }

  named_scope :include_teacher, lambda{
    {:include => {:assignment => :teacher_enrollment} }
  }
  named_scope :include_assessment_requests, lambda {
    {:include => [:assessment_requests, :assigned_assessments] }
  }
  named_scope :include_versions, lambda{
    {:include => [:versions] }
  }
  named_scope :include_submission_comments, lambda{
    {:include => [:submission_comments] }
  }
  named_scope :speed_grader_includes, lambda{
    {:include => [:versions, :submission_comments, :attachments, :rubric_assessment]}
  }
  named_scope :for, lambda {|context|
    {:include => :assignment, :conditions => ['assignments.context_id = ? AND assignments.context_type = ?', context.id, context.class.to_s]}
  }
  named_scope :for_user, lambda {|user|
    user_id = user.is_a?(User) ? user.id : user
    {:conditions => ['submissions.user_id IN (?)', Array(user_id)]}
  }
  named_scope :needing_screenshot, lambda {
    {:conditions => ['submissions.submission_type = ? AND submissions.attachment_id IS NULL AND submissions.process_attempts < 3', 'online_url'], :order => :updated_at}
  }

  def needs_regrading?
    graded? && !grade_matches_current_submission?
  end

  def readable_state
    case workflow_state
    when 'submitted', 'pending_review'
      t 'state.submitted', 'submitted'
    when 'unsubmitted'
      t 'state.unsubmitted', 'unsubmitted'
    when 'graded'
      t 'state.graded', 'graded'
    end
  end

  def grading_type
    return nil unless self.assignment
    self.assignment.grading_type
  end

  # Note 2012-10-12:
  #   Deprecating this method due to view code in the model. The only place
  #   it appears to be used is in the _recent_feedback.html.erb partial.
  def readable_grade
    warn "[DEPRECATED] The Submission#readable_grade method will be removed soon"
    return nil unless grade
    case grading_type
      when 'points'
        "#{grade} #{t('out_of', 'out of')} #{assignment.points_possible}" rescue grade.capitalize 
      else
        grade.capitalize
    end
  end

  def last_teacher_comment
    submission_comments.reverse.find{|com| com.author_id != user_id}
  end

  def has_submission?
    !!self.submission_type
  end

  def quiz_submission_version
    return nil unless self.quiz_submission
    self.quiz_submission.versions.each do |version|
      return version.number if version.model.finished_at
    end
    nil
  end

  named_scope :for, lambda { |obj|
    case obj
    when User
      {:conditions => ['user_id = ?', obj]}
    else
      {}
    end
  }

  def processed?
    if submission_type == "online_url"
      return attachment && attachment.content_type.match(/image/)
    end
    false
  end

  def add_comment(opts={})
    opts.symbolize_keys!
    opts[:author] = opts.delete(:commenter) || opts.delete(:author) || self.user
    opts[:comment] = opts[:comment].try(:strip) || ""
    opts[:attachments] ||= opts.delete :comment_attachments
    if opts[:comment].empty? 
      if opts[:media_comment_id]
        opts[:comment] = t('media_comment', "This is a media comment.")
      elsif opts[:attachments].try(:length)
        opts[:comment] = t('attached_files_comment', "See attached files.")
      end
    end
    if self.group
      # this is a bit icky, as it assumes the same opts hash will be passed in to each add_comment call for the group
      opts[:group_comment_id] ||= AutoHandle.generate_securish_uuid
    end
    self.save! if self.new_record?
    valid_keys = [:comment, :author, :media_comment_id, :media_comment_type, :group_comment_id, :assessment_request, :attachments, :anonymous, :hidden]
    comment = self.submission_comments.create(opts.slice(*valid_keys)) if !opts[:comment].empty?
    opts[:assessment_request].comment_added(comment) if opts[:assessment_request] && comment
    comment
  end

  def conversation_groups
    participating_instructors.map{ |i| [user, i] }
  end

  def conversation_message_data
    latest = visible_submission_comments.scoped(:conditions => ["author_id IN (?)", possible_participants_ids]).last or return
    {
      :created_at => latest.created_at,
      :author => latest.author,
      :body => latest.comment
    }
  end

  def comment_authors
    visible_submission_comments(:include => :author).map(&:author)
  end

  def commenting_instructors
    comment_authors & context.instructors
  end
  memoize :commenting_instructors

  def participating_instructors
    commenting_instructors.present? ? commenting_instructors : context.participating_instructors.uniq
  end

  def possible_participants_ids
    [user_id] + context.participating_instructors.uniq.map(&:id)
  end

  # ensure that conversations/messages are created/updated for all relevant
  # participants as submission comments are added/removed. there should be a
  # conversation between the submitter and each participating admin, and it
  # should have a single conversation_message that represents the submission
  # (there may of course be other regular messages in the conversation)
  #
  # ==== Arguments
  # * <tt>trigger</tt> - Values of :create, :destroy, :migrate are supported.
  # * <tt>overrides</tt> - Hash of overrides that can be passed through when
  #                        updating the conversation.
  #
  # ==== Overrides
  # * <tt>:skip_users</tt> - Gets passed through to <tt>Conversation</tt>.<tt>update_all_for_asset</tt>.
  #                        nil by default, which means mark-as-unread for
  #                        everyone but the author.
  def create_or_update_conversations!(trigger, overrides={})
    options = {}
    case trigger
    when :create
      options[:update_participants] = true
      options[:update_for_skips] = false
      options[:skip_users] = overrides[:skip_users] || [conversation_message_data[:author]] # don't mark-as-unread for the author
      participating_instructors.each do |t|
        # Check their settings and add to :skip_users if set to suppress.
        options[:skip_users] << t if t.preferences[:no_submission_comments_inbox] == true
      end
    when :destroy
      options[:delete_all] = visible_submission_comments.empty?
      options[:only_existing] = true
    when :migrate # don't mark-as-unread for anybody or add to empty conversations
      return unless conversation_message_data
      options[:recalculate_count] = true
      options[:recalculate_last_authored_at] = true
      options[:only_existing] = true
    end

    Conversation.update_all_for_asset(self, options)
  end

  def self.batch_migrate_conversations!(ids)
    find_all_by_id(ids).each do |sub|
      sub.create_or_update_conversations!(:migrate)
    end
  end

  def limit_comments(user, session=nil)
    @comment_limiting_user = user
    @comment_limiting_session = session
  end

  alias_method :old_submission_comments, :submission_comments
  def submission_comments(*args)
    res = old_submission_comments(*args)
    res = res.select{|sc| sc.grants_right?(@comment_limiting_user, @comment_limiting_session, :read) } if @comment_limiting_user
    res
  end

  alias_method :old_visible_submission_comments, :visible_submission_comments
  def visible_submission_comments(*args)
    res = old_visible_submission_comments(*args)
    res = res.select{|sc| sc.grants_right?(@comment_limiting_user, @comment_limiting_session, :read) } if @comment_limiting_user
    res
  end

  def assessment_request_count
    @assessment_requests_count ||= self.assessment_requests.length
  end

  def assigned_assessment_count
    @assigned_assessment_count ||= self.assigned_assessments.length
  end

  def assign_assessment(obj)
    @assigned_assessment_count ||= 0
    @assigned_assessment_count += 1
    assigned_assessments << obj
    touch
  end
  protected :assign_assessment

  def assign_assessor(obj)
    @assessment_request_count ||= 0
    @assessment_request_count += 1
    user = obj.user rescue nil
    association = self.assignment.rubric_association
    res = self.assessment_requests.find_or_initialize_by_assessor_asset_id_and_assessor_asset_type_and_assessor_id_and_rubric_association_id(obj.id, obj.class.to_s, user.id, (association ? association.id : nil))
    res || self.assessment_requests.build(:assessor_asset => obj, :assessor => user, :rubric_association => association)
    res.user_id = self.user_id
    res.workflow_state = 'assigned' if res.new_record?
    just_created = res.new_record?
    res.save
    case obj
    when User
      user = obj
    when Submission
      obj.assign_assessment(res) if just_created
    end
    res
  end

  def students
    self.group ? self.group.users : [self.user]
  end

  def save_without_broadcast
    @suppress_broadcast = true
    self.save!
    @suppress_broadcast = false
  end

  def broadcast_group_submission
    @group_broadcast_submission = true
    self.save!
    @group_broadcast_submission = false
  end

  def compute_lateness
    overridden_assignment = assignment.overridden_for(self.user)

    check_time = submitted_at
    check_time -= 60.seconds if submission_type == 'online_quiz'

    late = submitted_at &&
      overridden_assignment.due_at &&
      overridden_assignment.due_at < check_time

    write_attribute :late, !!late
  end

  def graded?
    !!self.score && self.workflow_state == 'graded'
  end
  
  def current_submission_graded?
    self.graded? && (!self.submitted_at || (self.graded_at && self.graded_at >= self.submitted_at))
  end
  
  def context(user=nil)
    self.assignment.context if self.assignment
  end
  
  def to_atom(opts={})
    prefix = self.assignment.context_prefix || ""
    author_name = self.assignment.present? && self.assignment.context.present? ? self.assignment.context.name : t('atom_no_author', "No Author")
    Atom::Entry.new do |entry|
      entry.title     = "#{self.user && self.user.name} -- #{self.assignment && self.assignment.title}#{", " + self.assignment.context.name if opts[:include_context]}"
      entry.authors  << Atom::Person.new(:name => author_name)
      entry.updated   = self.updated_at
      entry.published = self.created_at
      entry.id        = "tag:#{HostUrl.default_host},#{self.created_at.strftime("%Y-%m-%d")}:/submissions/#{self.feed_code}_#{self.updated_at.strftime("%Y-%m-%d")}"
      entry.links    << Atom::Link.new(:rel => 'alternate', 
                                    :href => "http://#{HostUrl.context_host(self.assignment.context)}/#{prefix}/assignments/#{self.assignment_id}/submissions/#{self.id}")
      entry.content   = Atom::Content::Html.new(self.body || "")
      # entry.author    = Atom::Person.new(self.user)
    end
  end

  # This little chunk makes it so that to_json will force it to always include the method :attachments
  # it is especially needed in the extended gradebook so that when we grab all of the versions through simply_versioned
  # that each of those versions include :attachments
  alias_method :ar_to_json, :to_json
  def to_json(options = {}, &block)
    if simply_versioned_version_model
      options[:methods] ||= []
      options[:methods] = Array(options[:methods])
      options[:methods] << :versioned_attachments
      options[:methods].uniq!
    end
    self.ar_to_json(options, &block)
    # default_options = { :methods => [ :attachments ]}
    # options[:methods] = [options[:methods]] if options[:methods] && !options[:methods].is_a?(Array)
    # default_options[:methods] += options[:methods] if options[:methods]
    # self.ar_to_json(options.merge(default_options), &block)
  end
  
  def self.json_serialization_full_parameters(additional_parameters={})
    includes = { :attachments => {}, :quiz_submission => {} }
    methods = [ :scribdable?, :conversion_status, :scribd_doc, :formatted_body, :submission_history ]
    methods << (additional_parameters.delete(:comments) || :submission_comments)
    excepts = additional_parameters.delete :except

    res = { :methods => methods, :include => includes }.merge(additional_parameters)
    if excepts
      excepts.each do |key|
        res[:methods].delete key
        res[:include].delete key
      end
    end
    res
  end

  def clone_for(context, dup=nil, options={})
    return nil unless params[:overwrite]
    submission = self.assignment.find_or_create_submission(self.user_id)
    self.attributes.delete_if{|k,v| [:id, :assignment_id, :user_id].include?(k.to_sym) }.each do |key, val|
      submission.send("#{key}=", val)
    end
    submission
  end
  
  def course_id=(val)
  end
  
  def to_param
    user_id
  end
  
  def turnitin_data_changed!
    @turnitin_data_changed = true
  end
  
  def changes_worth_versioning?
    !(self.changes.keys - [
      "updated_at", 
      "processed", 
      "process_attempts", 
      "changed_since_publish",
      "grade_matches_current_submission",
      "published_score",
      "published_grade"
    ]).empty? || @turnitin_data_changed
  end
  
  def get_web_snapshot
    # This should always be called in the context of a delayed job
    return unless CutyCapt.enabled?

    attachment = CutyCapt.snapshot_attachment_for_url(self.url)
    attachment.context = self
    attachment.save!
    attach_screenshot(attachment)
  end
  
  def attach_screenshot(attachment)
    self.attachment = attachment
    self.processed = true
    self.save!
  end

  def comments_for(user)
    grants_right?(user, :read_grade)? submission_comments : visible_submission_comments
  end

  def filter_attributes_for_user(hash, user, session)
    unless grants_right?(user, :read_grade)
      %w(score published_grade published_score grade).each do |secret_attr|
        hash.delete secret_attr
      end
    end
    hash
  end

  def create_outcome_result(alignment, explicit_mastery=false)
    # find or create the user's unique LearningOutcomeResult for this alignment
    # of the submission's assignment.
    result = alignment.learning_outcome_results.
      for_association(assignment).
      find_or_initialize_by_user_id(user.id)

    # force the context and artifact
    result.artifact = self
    result.context = alignment.context

    # mastery
    result.possible = assignment.points_possible
    result.score = score
    if alignment.tag == "points_mastery"
      result.mastery = result.score && assignment.mastery_score && result.score >= assignment.mastery_score
    elsif alignment.tag == "explicit_mastery"
      result.mastery = explicit_mastery
    else
      result.mastery = nil
    end

    # attempt
    result.attempt = attempt

    # title
    result.title = "#{user.name}, #{assignment.title}"

    result.assessed_at = Time.now
    result.save_to_version(result.attempt)
    result
  end

  def update_participation
    return if assignment.deleted? || assignment.muted?
    return unless self.user_id

    if self.score_changed? || self.grade_changed?
      ContentParticipation.create_or_update({
        :content => self,
        :user => self.user,
        :workflow_state => "unread",
      })
    end
  end

  def read_state(current_user)
    return "read" unless current_user #default for logged out user
    uid = current_user.is_a?(User) ? current_user.id : current_user
    state = content_participations.find_by_user_id(uid).try(:workflow_state)
    return state if state.present?
    return "read" if (assignment.deleted? || assignment.muted? || !self.user_id)
    return "unread" if (self.grade || self.score)
    return "unread" if self.submission_comments.scoped(:conditions => ["author_id <> ?", user_id]).first.present?
    return "read"
  end

  def read?(current_user)
    read_state(current_user) == "read"
  end

  def unread?(current_user)
    !read?(current_user)
  end

  def change_read_state(new_state, current_user)
    return nil unless current_user
    return true if new_state == self.read_state(current_user)

    ContentParticipation.create_or_update({
      :content => self,
      :user => current_user,
      :workflow_state => new_state,
    })
  end

  def mute
    self.published_score = 
      self.published_grade = 
      self.graded_at = 
      self.grade =
      self.score = nil
  end

  def muted_assignment?
    self.assignment.muted?
  end

  def without_graded_submission?
    !self.has_submission? && !self.graded?
  end
end
