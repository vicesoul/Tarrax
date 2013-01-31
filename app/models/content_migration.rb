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

class ContentMigration < ActiveRecord::Base
  require 'aws/s3'
  include AWS::S3
  include Workflow
  belongs_to :context, :polymorphic => true
  belongs_to :user
  belongs_to :attachment
  belongs_to :overview_attachment, :class_name => 'Attachment'
  belongs_to :exported_attachment, :class_name => 'Attachment'
  belongs_to :source_course, :class_name => 'Course'
  has_one :content_export
  has_a_broadcast_policy
  serialize :migration_settings
  before_save :infer_defaults
  cattr_accessor :export_file_path
  DATE_FORMAT = "%m/%d/%Y"
  DEFAULT_TO_EXPORT = {
          'all_files' => false,
          'announcements' => false,
          'assessments' => false,
          'assignment_groups' => true,
          'assignments' => false,
          'calendar_events' => false,
          'calendar_start' => 1.year.ago.strftime(DATE_FORMAT),
          'calendar_end' => 1.year.from_now.strftime(DATE_FORMAT),
          'course_outline' => true,
          'discussions' => false,
          'discussion_responses' => false,
          'goals' => false,
          'groups' => false,
          'learning_modules' => false,
          'question_bank' => false,
          'rubrics' => false,
          'tasks' => false,
          'web_links' => false,
          'wikis' => false
  }
  attr_accessible :context, :migration_settings, :user, :source_course, :copy_options
  attr_accessor :outcome_to_id_map

  workflow do
    state :created
    #The pre_process states can be used by individual plugins as needed
    state :pre_processing
    state :pre_processed
    state :pre_process_error
    state :exporting
    state :exported
    state :importing
    state :imported
    state :failed
  end

  set_broadcast_policy do |p|
    p.dispatch :migration_export_ready
    p.to { [user] }
    p.whenever {|record|
      record.changed_state(:exported) && !record.migration_settings[:skip_import_notification]
    }

    p.dispatch :migration_import_finished
    p.to { [user] }
    p.whenever {|record|
      record.changed_state(:imported) && !record.migration_settings[:skip_import_notification]
    }

    p.dispatch :migration_import_failed
    p.to { [user] }
    p.whenever {|record|
      record.changed_state(:failed) && !record.migration_settings[:skip_import_notification]
    }
  end

  # the stream item context is decided by calling asset.context(user), i guess
  # to differentiate from the normal asset.context() call that may not give us
  # the context we want. in this case, they're one and the same.
  alias_method :original_context, :context
  def context(user = nil)
    self.original_context
  end

  def migration_settings
    read_attribute(:migration_settings) || write_attribute(:migration_settings,{}.with_indifferent_access)
  end

  def update_migration_settings(new_settings)
    new_settings.each do |key, val|
      if key == 'only'
        process_to_scrape val
      else
        migration_settings[key] = val
      end
    end
  end
  
  def import_immediately?
    !!migration_settings[:import_immediately]
  end
  
  def converter_class=(c_class)
    migration_settings[:converter_class] = c_class
  end
  
  def converter_class
    migration_settings[:converter_class]
  end

  def strand=(s)
    migration_settings[:strand] = s
  end

  def strand
    migration_settings[:strand]
  end
  
  def migration_ids_to_import=(val)
    migration_settings[:migration_ids_to_import] = val
  end

  def infer_defaults
    migration_settings[:to_scrape] ||= DEFAULT_TO_EXPORT
  end

  def process_to_scrape(hash)
    migrate_only = migration_settings[:to_scrape] || DEFAULT_TO_EXPORT
    hash.each do |key, arg|
      migrate_only[key] = arg == '1' ? true : false if arg
      if key == 'calendar_events' && migrate_only[key]
        migrate_only['calendar_start'] = 1.year.ago.strftime(DATE_FORMAT)
        migrate_only['calendar_end'] = 1.year.from_now.strftime(DATE_FORMAT)
      end
    end
    migration_settings[:to_scrape] = migrate_only
  end

  def zip_path=(val)
    migration_settings[:export_archive_path] = val
  end

  def zip_path
    (migration_settings || {})[:export_archive_path]
  end

  def question_bank_name=(name)
    if name && name.strip! != ''
      migration_settings[:question_bank_name] = name
    end
  end

  def question_bank_name
    migration_settings[:question_bank_name]
  end

  def course_archive_download_url=(url)
    migration_settings[:course_archive_download_url] = url
  end

  def root_account
    self.context.root_account rescue nil
  end

  def plugin_type
    if plugin = Canvas::Plugin.find(migration_settings['migration_type'])
      plugin.metadata(:select_text) || plugin.name
    else
      t(:unknown, 'Unknown')
    end
  end

  # add a non-fatal error/warning to the import. user_message is what will be
  # displayed to the end user. exception_or_info can be either an Exception
  # object or any other information on the error.
  def add_warning(user_message, exception_or_info='')
    migration_settings[:warnings] ||= []
    if exception_or_info.is_a?(Exception)
      er = ErrorReport.log_exception(:content_migration, exception_or_info)
      migration_settings[:warnings] << [user_message, "ErrorReport:#{er.id}"]
    else
      migration_settings[:warnings] << [user_message, exception_or_info]
    end
  end

  def warnings
    (migration_settings[:warnings] || []).map(&:first)
  end

  def export_content
    check_quiz_id_prepender
    plugin = Canvas::Plugin.find(migration_settings['migration_type'])
    if plugin
      begin
        if Canvas::Migration::Worker.const_defined?(plugin.settings['worker'])
          self.workflow_state = :exporting
          job = Canvas::Migration::Worker.const_get(plugin.settings['worker']).enqueue(self)
          self.save
          job
        else
          raise NameError
        end
      rescue NameError
        self.workflow_state = 'failed'
        message = "The migration plugin #{migration_settings['migration_type']} doesn't have a worker."
        migration_settings[:last_error] = message
        ErrorReport.log_exception(:content_migration, $!)
        logger.error message
        self.save
      end
    else
      self.workflow_state = 'failed'
      message = "No migration plugin of type #{migration_settings['migration_type']} found."
      migration_settings[:last_error] = message
      logger.error message
      self.save
    end
  end

  def check_quiz_id_prepender
    if !migration_settings[:id_prepender] && !migration_settings[:overwrite_questions]
      # only prepend an id if the course already has some migrated questions/quizzes
      if self.context.assessment_questions.scoped(:conditions => 'assessment_questions.migration_id IS NOT NULL').any? ||
         (self.context.respond_to?(:quizzes) && self.context.quizzes.scoped(:conditions => 'quizzes.migration_id IS NOT NULL').any?)
        migration_settings[:id_prepender] = self.id
      end
    end
  end

  def to_import(val)
    migration_settings[:migration_ids_to_import] && migration_settings[:migration_ids_to_import][:copy] && migration_settings[:migration_ids_to_import][:copy][val]
  end

  def import_object?(asset_type, mig_id)
    return false unless mig_id
    return true unless migration_settings[:migration_ids_to_import] && migration_settings[:migration_ids_to_import][:copy] && migration_settings[:migration_ids_to_import][:copy].length > 0
    return true if is_set?(to_import(:everything))

    return true if is_set?(to_import("all_#{asset_type}"))

    return false unless to_import(asset_type)

    is_set?(to_import(asset_type)[mig_id])
  end

  def is_set?(option)
    Canvas::Plugin::value_to_boolean option
  end

  def import_content
    self.workflow_state = :importing
    self.save

    begin
      @exported_data_zip = download_exported_data
      @zip_file = Zip::ZipFile.open(@exported_data_zip.path)
      @exported_data_zip.close
      data = JSON.parse(@zip_file.read('course_export.json'), :max_nesting => 50)
      data = data.with_indifferent_access if data.is_a? Hash
      data['all_files_export'] ||= {}

      if @zip_file.find_entry('all_files.zip')
        # the file importer needs an actual file to process
        all_files_path = create_all_files_path(@exported_data_zip.path)
        @zip_file.extract('all_files.zip', all_files_path)
        data['all_files_export']['file_path'] = all_files_path
      else
        data['all_files_export']['file_path'] = nil
      end

      @zip_file.close

      migration_settings[:migration_ids_to_import] ||= {:copy=>{}}
      self.context.import_from_migration(data, migration_settings[:migration_ids_to_import], self)
    rescue => e
      self.workflow_state = :failed
      er = ErrorReport.log_exception(:content_migration, e)
      migration_settings[:last_error] = "ErrorReport:#{er.id}"
      logger.error e
      self.save
      raise e
    ensure
      clear_migration_data
    end
  end
  handle_asynchronously :import_content, :priority => Delayed::LOW_PRIORITY, :max_attempts => 1

  def copy_options
    self.migration_settings[:copy_options]
  end

  def copy_options=(options)
    self.migration_settings[:copy_options] = options
  end

  def for_course_copy?
    !!self.source_course
  end

  def copy_course
    self.workflow_state = :pre_processing
    self.progress = 0
    self.migration_settings[:skip_import_notification] = true
    self.save

    begin
      ce = ContentExport.new
      ce.content_migration = self
      ce.selected_content = copy_options
      ce.course = self.source_course
      ce.export_type = ContentExport::COURSE_COPY
      ce.user = self.user
      ce.save!
      self.content_export = ce

      ce.export_course_without_send_later

      if ce.workflow_state == 'exported_for_course_copy'
        # use the exported attachment as the import archive
        self.attachment = ce.attachment
        migration_settings[:migration_ids_to_import] ||= {:copy=>{}}
        migration_settings[:migration_ids_to_import][:copy][:everything] = true
        if copy_options[:shift_dates]
          migration_settings[:migration_ids_to_import][:copy][:shift_dates] = copy_options[:shift_dates]
          migration_settings[:migration_ids_to_import][:copy][:old_start_date] = copy_options[:old_start_date]
          migration_settings[:migration_ids_to_import][:copy][:old_end_date] = copy_options[:old_end_date]
          migration_settings[:migration_ids_to_import][:copy][:new_start_date] = copy_options[:new_start_date]
          migration_settings[:migration_ids_to_import][:copy][:new_end_date] = copy_options[:new_end_date]
          migration_settings[:migration_ids_to_import][:copy][:day_substitutions] = copy_options[:day_substitutions]
        end
        # set any attachments referenced in html to be copied
        ce.selected_content['attachments'] ||= {}
        ce.referenced_files.values.each do |att_mig_id|
          ce.selected_content['attachments'][att_mig_id] = true
        end
        ce.save

        self.save
        worker = Canvas::Migration::Worker::CCWorker.new
        worker.migration_id = self.id
        worker.perform
        self.reload
        if self.workflow_state == 'exported'
          self.workflow_state = :pre_processed
          self.progress = 10

          self.context.copy_attachments_from_course(self.source_course, :content_export => ce, :content_migration => self)
          self.progress = 20

          self.import_content_without_send_later
        end
      else
        self.workflow_state = :failed
        migration_settings[:last_error] = "ContentExport failed to export course."
        self.save
      end
    rescue => e
      self.workflow_state = :failed
      er = ErrorReport.log_exception(:content_migration, e)
      migration_settings[:last_error] = "ErrorReport:#{er.id}"
      logger.error e
      self.save
      raise e
    ensure
    end
  end
  handle_asynchronously :copy_course, :priority => Delayed::LOW_PRIORITY, :max_attempts => 1
  
  named_scope :for_context, lambda{|context|
    {:conditions => {:context_id => context.id, :context_type => context.class.to_s} }
  }
  
  named_scope :successful, :conditions=>"workflow_state = 'imported'"
  named_scope :running, :conditions=>"workflow_state IN ('exporting', 'importing')"
  named_scope :waiting, :conditions=>"workflow_state IN ('exported')"
  named_scope :failed, :conditions=>"workflow_state IN ('failed', 'pre_process_error')"

  def complete?
    %w[imported failed pre_process_error].include?(workflow_state)
  end

  def download_exported_data
    raise "No exported data to import" unless self.exported_attachment
    config = Setting.from_config('external_migration') || {}
    @exported_data_zip = self.exported_attachment.open(
      :need_local_file => true,
      :temp_folder => config[:data_folder])
    @exported_data_zip
  end
  
  def create_all_files_path(temp_path)
    "#{temp_path}_all_files.zip"
  end
  
  def clear_migration_data
    @zip_file.close if @zip_file
    @zip_file = nil
  end

  def progress
    return nil if self.workflow_state == 'created'
    mig_prog = read_attribute(:progress) || 0
    if self.source_course
      # this is for a course copy so it needs to combine the progress of the export and import
      # The export will count for 40% of progress
      # The importing step (so the value of progress on this object)will be 60%
      mig_prog = mig_prog * 0.6

      if self.content_export
        export_prog = self.content_export.progress || 0
        mig_prog += export_prog * 0.4
      end
    end

    mig_prog
  end

  def fast_update_progress(val)
    self.progress = val
    ContentMigration.update_all({:progress=>val}, "id=#{self.id}")
  end
end
