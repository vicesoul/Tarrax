#
# Copyright (C) 2011 - 2013 Instructure, Inc.
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

class Enrollment < ActiveRecord::Base

  include Workflow
  include Jxb::Base::Enrollment

  belongs_to :course, :touch => true
  belongs_to :course_section
  belongs_to :root_account, :class_name => 'Account'
  belongs_to :user
  belongs_to :associated_user, :class_name => 'User'
  has_many :role_overrides, :as => :context
  has_many :pseudonyms, :primary_key => :user_id, :foreign_key => :user_id
  has_many :course_account_associations, :foreign_key => 'course_id', :primary_key => 'course_id'

  validates_presence_of :user_id, :course_id
  validates_inclusion_of :limit_privileges_to_course_section, :in => [true, false]
  validates_inclusion_of :associated_user_id, :in => [nil],
                         :unless => lambda { |enrollment| enrollment.type == 'ObserverEnrollment' },
                         :message => "only ObserverEnrollments may have an associated_user_id"

  before_save :assign_uuid
  before_save :assert_section
  before_save :update_user_account_associations_if_necessary
  before_save :audit_groups_for_deleted_enrollments
  before_validation :infer_privileges
  after_create :create_linked_enrollments
  after_save :clear_email_caches
  after_save :cancel_future_appointments
  after_save :update_linked_enrollments

  attr_accessor :already_enrolled
  attr_accessible :user, :course, :workflow_state, :course_section, :limit_privileges_to_course_section, :already_enrolled

  def self.active_student_conditions(prefix = 'enrollments')
    "(#{prefix}.type IN ('StudentEnrollment', 'StudentViewEnrollment') AND #{prefix}.workflow_state = 'active')"
  end

  def self.active_student_subselect(conditions)
    "EXISTS (SELECT 1 FROM enrollments WHERE #{conditions} AND #{active_student_conditions} LIMIT 1)"
  end

  def self.needs_grading_trigger_sql
    no_other_enrollments_sql = "NOT " + active_student_subselect("user_id = NEW.user_id AND course_id = NEW.course_id AND id <> NEW.id")
    default_sql = <<-SQL
      UPDATE assignments SET needs_grading_count = needs_grading_count + %s, updated_at = {{now}}
      WHERE context_id = NEW.course_id
      AND context_type = 'Course'
      AND EXISTS (
        SELECT 1
        FROM submissions
        WHERE user_id = NEW.user_id
        AND assignment_id = assignments.id
        AND (#{Submission.needs_grading_conditions})
                LIMIT 1
      )
      AND #{no_other_enrollments_sql};
      SQL

    # IN (...) subselects perform poorly in mysql, plus we want to avoid locking rows in other tables
    # also, every database uses a different construct for a current UTC timestamp
    { :default    => default_sql.gsub("{{now}}", "now()"),
      :postgresql => default_sql.gsub("{{now}}", "now() AT TIME ZONE 'UTC'"),
      :sqlite     => default_sql.gsub("{{now}}", "datetime('now')"),
      :mysql => <<-MYSQL }
        IF #{no_other_enrollments_sql} THEN
          UPDATE assignments, submissions SET needs_grading_count = needs_grading_count + %s, assignments.updated_at = utc_timestamp()
          WHERE context_id = NEW.course_id
            AND context_type = 'Course'
            AND assignments.id = submissions.assignment_id
            AND submissions.user_id = NEW.user_id
            AND (#{Submission.needs_grading_conditions});
        END IF;
      MYSQL
  end

  trigger.after(:insert).where(active_student_conditions('NEW')) do
    Hash[needs_grading_trigger_sql.map{|key, value| [key, value % 1]}]
  end

  trigger.after(:update).where("#{active_student_conditions('NEW')} <> #{active_student_conditions('OLD')}") do
    Hash[needs_grading_trigger_sql.map{|key, value| [key, value % "CASE WHEN NEW.workflow_state = 'active' THEN 1 ELSE -1 END"]}]
  end

  include StickySisFields
  are_sis_sticky :start_at, :end_at

  has_a_broadcast_policy

  set_broadcast_policy do |p|
    p.dispatch :enrollment_invitation
    p.to { self.user }
    p.whenever { |record|
      record.course and
      record.user.registered? and
      ((record.just_created && record.invited?) || record.changed_state(:invited) || @re_send_confirmation)
    }

    p.dispatch :enrollment_registration
    p.to { self.user.communication_channel }
    p.whenever { |record|
      record.course and
      !record.user.registered? and
      ((record.just_created && record.invited?) || record.changed_state(:invited) || @re_send_confirmation)
    }

    p.dispatch :enrollment_notification
    p.to { self.user }
    p.whenever { |record|
      record.course &&
      !record.course.created? &&
      record.just_created && record.active?
    }

    p.dispatch :enrollment_accepted
    p.to {self.course.admins - [self.user] }
    p.whenever { |record|
      record.course &&
      !record.just_created && (record.changed_state(:active, :invited) || record.changed_state(:active, :creation_pending))
    }
  end

  named_scope :active,
              :conditions => ['enrollments.workflow_state != ?', 'deleted']

  named_scope :deleted,
              :conditions => ['enrollments.workflow_state = ?', 'deleted']

  named_scope :admin,
              :select => 'course_id',
              :joins => :course,
              :conditions => "enrollments.type IN ('TeacherEnrollment','TaEnrollment', 'DesignerEnrollment')
                              AND (courses.workflow_state = 'claimed' OR (enrollments.workflow_state = 'active' and  courses.workflow_state = 'available'))"

  named_scope :of_admin_type,
              :conditions => "enrollments.type IN ('TeacherEnrollment','TaEnrollment', 'DesignerEnrollment')"

  named_scope :of_instructor_type,
              :conditions => "enrollments.type IN ('TeacherEnrollment','TaEnrollment')"

  named_scope :of_content_admins,
              :conditions => "enrollments.type IN ('TeacherEnrollment', 'DesignerEnrollment')"

  named_scope :student,
              :select => 'course_id',
              :joins => :course,
              :conditions => "enrollments.type = 'StudentEnrollment'
                              AND enrollments.workflow_state = 'active'
                              AND courses.workflow_state = 'available'"

  named_scope :student_in_claimed_or_available,
              :select => 'course_id',
              :joins => :course,
              :conditions => "enrollments.type = 'StudentEnrollment'
                              AND enrollments.workflow_state = 'active'
                              AND courses.workflow_state IN ('available', 'claimed')"

  named_scope :all_student,
              :include => :course,
              :conditions => "(enrollments.type = 'StudentEnrollment'
                              AND enrollments.workflow_state IN ('invited', 'active', 'completed')
                              AND courses.workflow_state IN ('available', 'completed')) OR
                              (enrollments.type = 'StudentViewEnrollment'
                              AND enrollments.workflow_state = 'active'
                              AND courses.workflow_state != 'deleted')"

  named_scope :ended,
              :joins => :course,
              :conditions => "courses.workflow_state = 'completed' or enrollments.workflow_state = 'rejected' or enrollments.workflow_state = 'completed'"

  named_scope :future, lambda { {
    :joins => :course,
    :conditions => ["courses.start_at > ?
                    AND courses.workflow_state = 'available'
                    AND courses.restrict_enrollments_to_course_dates = ?
                    AND enrollments.workflow_state IN ('invited', 'active', 'completed')", Time.now, true]
  } }

  named_scope :past,
              :joins => :course,
              :conditions => "(courses.workflow_state = 'completed'
                              AND enrollments.workflow_state NOT IN ('invited', 'deleted'))
                              OR enrollments.workflow_state IN ('rejected', 'completed')"

  named_scope :not_fake, :conditions => "enrollments.type != 'StudentViewEnrollment'"


  READABLE_TYPES = {
    'TeacherEnrollment' => t('#enrollment.roles.teacher', "Teacher"),
    'TaEnrollment' => t('#enrollment.roles.ta', "TA"),
    'DesignerEnrollment' => t('#enrollment.roles.designer', "Designer"),
    'StudentEnrollment' => t('#enrollment.roles.student', "Student"),
    'StudentViewEnrollment' => t('#enrollment.roles.student', "Student"),
    'ObserverEnrollment' => t('#enrollment.roles.observer', "Observer")
  }

  def self.readable_type(type)
    READABLE_TYPES[type] || READABLE_TYPES['StudentEnrollment']
  end

  SIS_TYPES = {
      'TeacherEnrollment' => 'teacher',
      'TaEnrollment' => 'ta',
      'DesignerEnrollment' => 'designer',
      'StudentEnrollment' => 'student',
      'ObserverEnrollment' => 'observer'
  }
  def self.sis_type(type)
    SIS_TYPES[type] || SIS_TYPES['StudentEnrollment']
  end

  def sis_role
    self.role_name || Enrollment.sis_type(self.type)
  end

  def self.valid_types
    SIS_TYPES.keys
  end

  def self.valid_type?(type)
    SIS_TYPES.has_key?(type)
  end

  def self.types_with_indefinite_article
    {
      'TeacherEnrollment' => t('#enrollment.roles.teacher_with_indefinite_article', "A Teacher"),
      'TaEnrollment' => t('#enrollment.roles.ta_with_indefinite_article', "A TA"),
      'DesignerEnrollment' => t('#enrollment.roles.designer_with_indefinite_article', "A Designer"),
      'StudentEnrollment' => t('#enrollment.roles.student_with_indefinite_article', "A Student"),
      'StudentViewEnrollment' => t('#enrollment.roles.student_with_indefinite_article', "A Student"),
      'ObserverEnrollment' => t('#enrollment.roles.observer_with_indefinite_article', "An Observer")
    }
  end

  def self.type_with_indefinite_article(type)
    types_with_indefinite_article[type] || types_with_indefinite_article['StudentEnrollment']
  end

  def should_update_user_account_association?
    self.new_record? || self.course_id_changed? || self.course_section_id_changed? || self.root_account_id_changed?
  end

  def update_user_account_associations_if_necessary
    return if self.fake_student?
    if self.new_record?
      return if %w{creation_pending deleted}.include?(self.user.workflow_state)
      associations = User.calculate_account_associations_from_accounts([self.course.account_id, self.course_section.course.account_id, self.course_section.nonxlist_course.try(:account_id)].compact.uniq)
      self.user.update_account_associations(:incremental => true, :precalculated_associations => associations)
    elsif should_update_user_account_association?
      self.user.update_account_associations_later
    end
  end
  protected :update_user_account_associations_if_necessary

  def audit_groups_for_deleted_enrollments
    # did the student cease to be enrolled in a non-deleted state in a section?
    had_section = self.course_section_id_was.present?
    was_active = (self.workflow_state_was != 'deleted')
    return unless had_section && was_active &&
                  (self.course_section_id_changed? || self.workflow_state == 'deleted')

    # what section the user is abandoning, and the section they're moving to
    # (if it's in the same course and the enrollment's not deleted)
    section = CourseSection.find(self.course_section_id_was)

    # ok, consider groups the user is in from the abandoned section's course
    self.user.groups.scoped(:include => :group_category, :conditions =>
      ['context_type=? AND context_id=?',
       'Course', section.course_id]).each do |group|

      # don't bother unless the group's category has section restrictions or
      # the enrollment was deleted
      next unless group.group_category && group.group_category.restricted_self_signup? || self.workflow_state == 'deleted'

      if self.workflow_state != 'deleted' # if deleted, we'll always remove the user
        # skip if the user is the only user in the group. there's no one to have
        # a conflicting section.
        next if group.users.count == 1

        # check if the group has the section the user is abandoning as a common
        # section (from CourseSection#common_to_users? view, the enrollment is
        # still there since it queries the db directly and we haven't saved yet);
        # if not, dropping the section is not necessary
        next unless section.common_to_users?(group.users)
      end

      # at this point, we know there's another user, and he's in the abandoned
      # section, and a student *should* only be in one section, so there's no
      # way for any other sections to be common between them. alternatively,
      # we have just deleted the user's enrollment in the group's course.
      # remove the leaving user from the group to keep the group happy
      membership = group.group_memberships.find_by_user_id(self.user_id)
      membership.destroy if membership
    end
  end
  protected :audit_groups_for_deleted_enrollments

  def observers
    student? ? user.observers : []
  end

  def create_linked_enrollments
    observers.each do |observer|
      create_linked_enrollment_for(observer)
    end
  end

  def update_linked_enrollments
    observers.each do |observer|
      if enrollment = linked_enrollment_for(observer)
        enrollment.update_from(self)
      end
    end
  end

  def create_linked_enrollment_for(observer)
    enrollment = linked_enrollment_for(observer) || observer.observer_enrollments.build
    enrollment.associated_user_id = user_id
    enrollment.update_from(self)
  end

  def linked_enrollment_for(observer)
    # there should really only ever be one, but due to SIS or legacy data there
    # could be multiple. we'll use the best match (based on workflow_state)
    enrollment = observer.observer_enrollments.find :first, :conditions => {
      :associated_user_id => user_id,
      :course_id => course_id,
      :course_section_id => course_section_id_was
    }, :order => self.class.state_rank_sql
    # we don't want to "undelete" observer enrollments that have been
    # explicitly deleted 
    return nil if enrollment && enrollment.deleted? && workflow_state_was != 'deleted'
    enrollment
  end

  def update_from(other)
    self.course_id = other.course_id
    self.workflow_state = other.workflow_state
    self.start_at = other.start_at
    self.end_at = other.end_at
    self.course_section_id = other.course_section_id
    self.root_account_id = other.root_account_id
    self.user.touch if workflow_state_changed?
    save!
  end

  def clear_email_caches
    if self.workflow_state_changed? && (self.workflow_state_was == 'invited' || self.workflow_state == 'invited')
      if Enrollment.cross_shard_invitations?
        Shard.default.activate do
          self.user.communication_channels.email.unretired.each { |cc| Rails.cache.delete([cc.path, 'all_invited_enrollments'].cache_key)}
        end
      else
        self.user.communication_channels.email.unretired.each { |cc| Rails.cache.delete([cc.path, 'invited_enrollments'].cache_key)}
      end
    end
  end

  def cancel_future_appointments
    if workflow_state_changed? && completed?
      course.appointment_participants.active.current.for_context_codes(user.asset_string).update_all(:workflow_state => 'deleted')
    end
  end

  def conclude
    self.workflow_state = "completed"
    self.completed_at = Time.now
    self.user.touch
    self.save
  end

  def defined_by_sis?
    !!self.sis_source_id
  end

  def assigned_observer?
    self.observer? && self.associated_user_id
  end

  def participating?
    self.state_based_on_date == :active
  end

  def participating_student?
    self.student? && self.participating?
  end

  def participating_observer?
    self.observer? && self.participating?
  end

  def participating_teacher?
    self.teacher? && self.participating?
  end

  def participating_ta?
    self.ta? && self.participating?
  end

  def participating_instructor?
    self.instructor? && self.participating?
  end

  def participating_designer?
    self.designer? && self.participating?
  end

  def participating_admin?
    self.admin? && self.participating?
  end

  def participating_content_admin?
    self.content_admin? && self.participating?
  end

  def associated_user_name
    self.associated_user && self.associated_user.short_name
  end

  def assert_section
    self.course_section ||= self.course.default_section if self.course
    self.root_account_id = self.course.root_account_id rescue nil
  end

  def infer_privileges
    # limit_privileges_to_course_section affects whether this user can see
    # users from other sections (for any purpose - messaging, roster, grading)
    # admins (teacher, ta, designer) that have this flag are also visible TO
    # users from any section (but not students/observers).
    # currently, this flag is actually only configurable for teachers and
    # TAs; designers are always course-wide, and so are students.
    # In the future, we should probably allow configuring it for students,
    # possibly section-wide (i.e. "Students in this section can see students
    # from all other sections")
    if self.is_a?(TeacherEnrollment) || self.is_a?(TaEnrollment)
      self.limit_privileges_to_course_section = false if self.limit_privileges_to_course_section.nil?
    else
      self.limit_privileges_to_course_section = false
    end
    true
  end

  def course_name
    self.course.name || t('#enrollment.default_course_name', "Course")
  end

  def short_name(length=nil)
    return @short_name if @short_name
    @short_name = self.course_section.display_name if self.course_section && self.root_account && self.root_account.show_section_name_as_course_name
    @short_name ||= self.course_name
    @short_name = @short_name[0..length] if length
    @short_name
  end

  def long_name
    return @long_name if @long_name
    @long_name = self.course_name
    @long_name = t('#enrollment.with_section', "%{course_name}, %{section_name}", :course_name => @long_name, :section_name => self.course_section.display_name) if self.course_section && self.course_section.display_name && self.course_section.display_name != self.course.name
    @long_name
  end

  TYPE_RANKS = {
    :default => ['TeacherEnrollment','TaEnrollment','DesignerEnrollment','StudentEnrollment','StudentViewEnrollment','ObserverEnrollment'],
    :student => ['StudentEnrollment','TeacherEnrollment','TaEnrollment','DesignerEnrollment','StudentViewEnrollment','ObserverEnrollment']
  }
  TYPE_RANK_HASHES = Hash[TYPE_RANKS.map{ |k, v| [k, rank_hash(v)] }]
  def self.type_rank_sql(order = :default)
    # don't call rank_sql during class load
    rank_sql(TYPE_RANKS[order], 'enrollments.type')
  end

  def rank_sortable(order = :default)
    TYPE_RANK_HASHES[order][self.class.to_s]
  end

  STATE_RANK = ['active', ['invited', 'creation_pending'], 'completed', 'rejected', 'deleted']
  STATE_RANK_HASH = rank_hash(STATE_RANK)
  def self.state_rank_sql
    # don't call rank_sql during class load
    @state_rank_sql ||= rank_sql(STATE_RANK, 'enrollments.workflow_state')
  end

  def state_sortable
    STATE_RANK_HASH[state.to_s]
  end

  def accept!
    res = accept
    raise "can't accept" unless res
    res
  end

  def accept(force = false)
    return false unless force || invited?
    ids = nil
    ids = self.user.dashboard_messages.find_all_by_context_id_and_context_type(self.id, 'Enrollment', :select => "id").map(&:id) if self.user
    Message.delete_all({:id => ids}) if ids && !ids.empty?
    update_attribute(:workflow_state, 'active')
    touch_user
  end

  workflow do
    state :invited do
      event :reject, :transitions_to => :rejected do self.user.touch; end
      event :complete, :transitions_to => :completed
      event :pend, :transitions_to => :pending
    end

    state :creation_pending do
      event :invite, :transitions_to => :invited
    end

    state :active do
      event :reject, :transitions_to => :rejected do self.user.touch; end
      event :complete, :transitions_to => :completed
      event :pend, :transitions_to => :pending
    end

    state :deleted
    state :rejected do
      event :unreject, :transitions_to => :invited
    end
    state :completed

    # Inactive is a "hard" state, i.e. tuition not paid
    state :inactive
  end

  def enrollment_dates
    Canvas::Builders::EnrollmentDateBuilder.build(self)
  end

  def state_based_on_date
    return state unless [:invited, :active].include?(state)

    ranges = self.enrollment_dates
    now    = Time.now
    ranges.each do |range|
      start_at, end_at = range
      # start_at <= now <= end_at, allowing for open ranges on either end
      return state if (start_at || now) <= now && now <= (end_at || now)
    end

    # Not strictly within any range
    return state unless global_start_at = ranges.map(&:compact).map(&:min).compact.min
    if global_start_at < now
      :completed
    # Allow student view students to use the course before the term starts
    elsif self.fake_student? || state == :invited
      state
    else
      :inactive
    end
  end

  def active?
    state_based_on_date == :active
  end

  def inactive?
    state_based_on_date == :inactive
  end

  def invited?
    state_based_on_date == :invited
  end

  def completed?
    state_based_on_date == :completed
  end

  def explicitly_completed?
    state == :completed
  end

  def soft_completed_at
    enrollment_dates.map(&:last).compact.min
  end
  protected :soft_completed_at

  def completed_at
    read_attribute(:completed_at) || (completed? ? soft_completed_at : nil)
  end

  alias_method :destroy!, :destroy
  def destroy
    self.workflow_state = 'deleted'
    result = self.save
    self.user.try(:update_account_associations) if result
    result
  end

  def restore
    self.workflow_state = 'active'
    self.save
  end

  def re_send_confirmation!
    @re_send_confirmation = true
    self.save
    @re_send_confirmation = false
    true
  end

  def has_permission_to?(action)
    @permission_lookup ||= {}
    unless @permission_lookup.has_key? action
      @permission_lookup[action] = RoleOverride.enabled_for?(course, course, action, base_role_name, self.role_name)
    end
    @permission_lookup[action].include?(:self)
  end

  def base_role_name
    self.class.to_s
  end

  # Determine if a user has permissions to conclude this enrollment.
  #
  # user    - The user requesting permission to conclude/delete enrollment.
  # context - The current context, e.g. course or section.
  # session - The current user's session (pass nil if not available).
  #
  # return Boolean
  def can_be_concluded_by(user, context, session)
    can_remove = [StudentEnrollment].include?(self.class) &&
      context.grants_right?(user, session, :manage_students)
    can_remove ||= context.grants_right?(user, session, :manage_admin_users)
  end

  # Determine if a user has permissions to delete this enrollment.
  #
  # user    - The user requesting permission to conclude/delete enrollment.
  # context - The current context, e.g. course or section.
  # session - The current user's session (pass nil if not available).
  #
  # return Boolean
  def can_be_deleted_by(user, context, session)
    can_remove = [StudentEnrollment, ObserverEnrollment].include?(self.class) &&
      context.grants_right?(user, session, :manage_students)
    can_remove ||= context.grants_right?(user, session, :manage_admin_users)
    can_remove &&= self.user_id != user.id ||
      context.account.grants_right?(user, session, :manage_admin_users)
  end

  def pending?
    self.invited? || self.creation_pending?
  end

  def active_or_pending?
    self.active? || self.inactive? || self.pending?
  end

  def email
    self.user.email rescue t('#enrollment.default_email', "No Email")
  end

  def user_name
    read_attribute(:user_name) || self.user.name rescue t('#enrollment.default_user_name', "Unknown User")
  end

  def context
    @context ||= course
  end

  def context_id
    @context_id ||= course_id
  end

  def can_switch_to?(type)
    case type
    when 'ObserverEnrollment'
      ['TeacherEnrollment', 'TaEnrollment', 'DesignerEnrollment'].include?(self.type)
    when 'StudentEnrollment'
      ['TeacherEnrollment', 'TaEnrollment', 'DesignerEnrollment'].include?(self.type)
    when 'TaEnrollment'
      ['TeacherEnrollment'].include?(self.type)
    else
      false
    end
  end

  def self.workflow_readable_type(state)
    case state.to_s
      when 'active'
        t('#enrollment.workflow.active', "Active")
      when 'completed'
        t('#enrollment.workflow.completed', "Completed")
      when 'deleted'
        t('#enrollment.workflow.deleted', "Deleted")
      when 'invited'
        t('#enrollment.workflow.invited', "Invited")
      when 'pending'
        t('#enrollment.workflow.pending', "Pending")
      when 'rejected'
        t('#enrollment.workflow.rejected', "Rejected")
      when 'inactive'
        t('#enrollment.workflow.inactive', "Inactive")
    end
  end

  def workflow_readable_type
    Enrollment.workflow_readable_type(self.workflow_state)
  end

  def readable_type
    Enrollment.readable_type(self.class.to_s)
  end

  def self.recompute_final_scores(user_id)
    user = User.find(user_id)
    enrollments = user.student_enrollments.uniq_by { |e| e.course_id }
    enrollments.each do |enrollment|
      send_later(:recompute_final_score, user_id, enrollment.course_id)
    end
  end

  # This is called to recompute the users' cached scores for a given course
  # when:
  #
  # * The user is merged with another user; the scores are recomputed for the
  #   new user in each of his/her courses.
  #
  # * An assignment's default grade is changed; all users in the assignment's
  #   course have their scores for that course recomputed.
  #
  # * A course is merged into another, a section is crosslisted/uncrosslisted,
  #   or a section is otherwise moved between courses; scores are recomputed
  #   for all users in the target course.
  #
  # * A course's group_weighting_scheme is changed; scores are recomputed for
  #   all users in the course.
  #
  # * Assignments are reordered (since an assignment may change groups, which
  #   may have weights); scores are recomputed for all users in the associated
  #   course.
  #
  # * An assignment's points_possible is changed; scores are recomputed for all
  #   users in the associated course.
  #
  # * An assignment group's rules or group_weight are changed; scores are
  #   recomputed for all users in the associated course.
  #
  # * A submission's score is changed; scores for the submission owner in the
  #   associated course are recomputed.
  #
  # * An assignment is deleted/undeleted
  #
  # If some new feature comes up that affects calculation of a user's score,
  # please add appropriate calls to this so that the cached values don't get
  # stale! And once you've added the call, add the condition to the comment
  # here for future enlightenment.
  def self.recompute_final_score(user_ids, course_id)
    GradeCalculator.recompute_final_score(user_ids, course_id)
  end

  def self.recompute_final_score_if_stale(course, user=nil)
    Rails.cache.fetch(['recompute_final_scores', course.id, user].cache_key, :expires_in => Setting.get_cached('recompute_grades_window', 600).to_i.seconds) do
      recompute_final_score user ? user.id : course.student_enrollments.map(&:user_id), course.id
      yield if block_given?
      true
    end
  end

  def computed_final_grade
    self.course.score_to_grade(self.computed_final_score)
  end

  def self.students(opts={})
    with_scope :find => opts do
      find(:all, :conditions => {:type => 'Student'}).map(&:user).compact
    end
  end

  def self.typed_enrollment(type)
    return nil unless ['StudentEnrollment', 'StudentViewEnrollment', 'TeacherEnrollment', 'TaEnrollment', 'ObserverEnrollment', 'DesignerEnrollment'].include?(type)
    type.constantize
  end

  # overridden to return true in appropriate subclasses
  def student?
    false
  end

  def fake_student?
    false
  end

  def observer?
    false
  end

  def teacher?
    false
  end

  def ta?
    false
  end

  def designer?
    false
  end

  def instructor?
    teacher? || ta?
  end

  def admin?
    instructor? || designer?
  end

  def content_admin?
    teacher? || designer?
  end

  def to_atom
    Atom::Entry.new do |entry|
      entry.title     = t('#enrollment.title', "%{user_name} in %{course_name}", :user_name => self.user_name, :course_name => self.course_name)
      entry.updated   = self.updated_at
      entry.published = self.created_at
      entry.links    << Atom::Link.new(:rel => 'alternate',
                                    :href => "/courses/#{self.course.id}/enrollments/#{self.id}")
    end
  end

  set_policy do
    given { |user| self.user == user }
    can :read and can :read_grades

    given {|user, session| self.course.grants_right?(user, session, :participate_as_student) && self.user.show_user_services }
    can :read_services

    # read_services says this person has permission to see what web services this enrollment has linked to their account
    given {|user, session| self.course.grants_right?(user, session, :manage_students) && self.user.show_user_services }
    can :read and can :read_services

    given { |user, session| self.course.students_visible_to(user, true).map(&:id).include?(self.user_id) && self.course.grants_rights?(user, session, :manage_grades, :view_all_grades).values.any? }
    can :read and can :read_grades

    given { |user| course.observer_enrollments.find_by_user_id_and_associated_user_id(user.id, self.user_id).present? }
    can :read and can :read_grades and can :read_services
  end

  named_scope :before, lambda{|date|
    {:conditions => ['enrollments.created_at < ?', date]}
  }

  named_scope :for_user, lambda{|user|
    {:conditions => ['enrollments.user_id = ?', user.id] }
  }

  named_scope :for_courses_with_user_name, lambda{|courses|
    {
      :conditions => {:course_id => courses.map(&:id)},
      :joins => :user,
      :select => 'user_id, course_id, users.name AS user_name'
    }
  }
  named_scope :invited, :conditions => { :workflow_state => 'invited' }
  named_scope :accepted, :conditions => ['enrollments.workflow_state != ?', 'invited']
  named_scope :active_or_pending, :conditions => {:workflow_state => ['invited', 'creation_pending', 'active']}
  named_scope :currently_online, :joins => :pseudonyms, :conditions => ['pseudonyms.last_request_at > ?', 5.minutes.ago]
  # this returns enrollments for creation_pending users; should always be used in conjunction with the invited scope
  named_scope :for_email, lambda { |email|
    {
      :joins => { :user => :communication_channels },
      :conditions => ["users.workflow_state='creation_pending' AND communication_channels.workflow_state='unconfirmed' AND path_type='email' AND LOWER(path)=?", email.downcase],
      :select => 'enrollments.*',
      :readonly => false
    }
  }
  def self.cached_temporary_invitations(email)
    if Enrollment.cross_shard_invitations?
      Shard.default.activate do
        invitations = Rails.cache.fetch([email, 'all_invited_enrollments'].cache_key) do
          Shard.with_each_shard(CommunicationChannel.associated_shards(email)) do
            Enrollment.invited.for_email(email).to_a
          end
        end
      end
    else
      Rails.cache.fetch([email, 'invited_enrollments'].cache_key) do
        Enrollment.invited.for_email(email).to_a
      end
    end
  end

  def self.order_by_sortable_name(options = {})
    add_sort_key!(options, User.sortable_name_order_by_clause('users'))
    uber_scope(options)
  end

  def self.top_enrollment_by(key, rank_order = :default)
    raise "top_enrollment_by_user must be scoped" unless scoped?(:find, :conditions)
    key = key.to_s
    distinct_on(key, :order => "#{key}, #{type_rank_sql(rank_order)}")
  end

  def assign_uuid
    # DON'T use ||=, because that will cause an immediate save to the db if it
    # doesn't already exist
    self.uuid = AutoHandle.generate_securish_uuid if !read_attribute(:uuid)
  end
  protected :assign_uuid

  def uuid
    if !read_attribute(:uuid)
      self.update_attribute(:uuid, AutoHandle.generate_securish_uuid)
    end
    read_attribute(:uuid)
  end

  def self.limit_privileges_to_course_section!(course, user, limit)
    course.shard.activate do
      Enrollment.update_all({:limit_privileges_to_course_section => !!limit}, {:course_id => course.id, :user_id => user.id})
    end
    user.touch
  end

  def self.course_user_state(course, uuid)
    Rails.cache.fetch(['user_state', course, uuid].cache_key) do
      enrollment = course.enrollments.find_by_uuid(uuid)
      if enrollment
        {
          :enrollment_state => enrollment.workflow_state,
          :user_state => enrollment.user.state,
          :is_admin => enrollment.admin?
        }
      else
        nil
      end
    end
  end

  def self.serialization_excludes; [:uuid,:computed_final_score, :computed_current_score]; end

  # enrollment term per-section is deprecated; a section's term is inherited from the
  # course it is currently tied to
  def enrollment_term
    self.course.enrollment_term
  end

  def self.remove_duplicate_enrollments_from_sections
    # clean up for enrollments that aren't unique on (user_id,
    # course_section_id, type, associated_user_id)
    #
    # eventually we'll make this a db constraint, and we can drop this method,
    # but that'll require some more code changes
    deleted = 0
    while true
      pairs = self.connection.select_rows("
          SELECT user_id, course_section_id, type, associated_user_id
          FROM enrollments
          WHERE sis_source_id IS NOT NULL
          GROUP BY user_id, course_section_id, type, associated_user_id
          HAVING count(*) > 1 LIMIT 50000")
      break if pairs.empty?
      pairs.each do |(user_id, course_section_id, type, associated_user_id)|
        scope = self.scoped(:conditions => { :user_id => user_id, :course_section_id => course_section_id, :type => type, :associated_user_id => associated_user_id }).scoped(:conditions => "sis_source_id IS NOT NULL")
        keeper = scope.first(:select => "id, workflow_state", :order => 'sis_batch_id desc')
        deleted += scope.delete_all(["id<>?", keeper.id]) if keeper
      end
    end
    return deleted
  end

  # similar to above, but used on a scope or association (e.g. User#enrollments)
  def self.remove_duplicates!
    raise "remove_duplicates! needs to be scoped" unless scoped?(:find, :conditions)

    where(["workflow_state NOT IN (?)", ['deleted', 'inactive', 'rejected']]).
      group_by{ |e| [e.user_id, e.course_id, e.course_section_id, e.associated_user_id] }.
      each do |key, enrollments|
        next if enrollments.size == 1
        enrollments.
          sort_by{ |e| [e.sis_batch_id || ''] + [-e.state_sortable] }.
          reverse.
          slice(1, enrollments.size - 1).
          each(&:destroy)
      end
  end

  def effective_start_at
    # try and use the enrollment dates logic first, since it knows about
    # overrides, etc. but if it doesn't find anything, start guessing by
    # looking at the enrollment, section, course, then term. if we still didn't
    # find it, fall back to the section or course creation date.
    enrollment_dates.map(&:first).compact.min ||
    start_at ||
    course_section && course_section.start_at ||
    course.start_at ||
    course.enrollment_term && course.enrollment_term.start_at ||
    course_section && course_section.created_at ||
    course.created_at
  end

  def effective_end_at
    # try and use the enrollment dates logic first, since it knows about
    # overrides, etc. but if it doesn't find anything, start guessing by
    # looking at the enrollment, section, course, then term.
    enrollment_dates.map(&:last).compact.max ||
    end_at ||
    course_section && course_section.end_at ||
    course.conclude_at ||
    course.enrollment_term && course.enrollment_term.end_at
  end

  def self.cross_shard_invitations?
    false
  end

  def role
    self.role_name || self.type
  end

  # DO NOT TRUST
  # This is only a convenience method to assist in identifying which enrollment
  # goes to which user when users have accidentally been merged together
  # This is the *only* reason the sis_source_id column has not been dropped
  def sis_user_id
    return @sis_user_id if @sis_user_id
    sis_source_id_parts = sis_source_id ? sis_source_id.split(':') : []
    if sis_source_id_parts.length == 4
      @sis_user_id = sis_source_id_parts[1]
    else
      @sis_user_id = sis_source_id_parts[0]
    end
    @sis_user_id
  end
end
