module Api::V1
  module GradebookHistory
    include Api
    include Assignment

    def days_json(course, api_context)
      day_hash = Hash.new{|hash, date| hash[date] = {:graders => {}} }
      submissions_set(course, api_context).
        each_with_object(day_hash) { |submission, day| update_graders_hash(day[day_string_for(submission)][:graders], submission, api_context) }.
        each do |date, date_hash|
          compress(date_hash, :graders)
          date_hash[:graders].each { |grader| compress(grader, :assignments) }
        end

      day_hash.inject([]) do |memo, (date, hash)|
        memo << hash.merge(:date => date)
      end.sort { |a, b| b[:date] <=> a[:date] }
    end

    def json_for_date(date, course, api_context)
      submissions_set(course, api_context, :date => date).
        each_with_object(Hash.new) { |sub, memo| update_graders_hash(memo, sub, api_context) }.values.
        each { |grader| compress(grader, :assignments) }
    end

    def submissions_for(course, api_context, date, grader_id, assignment_id)
      assignment = ::Assignment.find(assignment_id)
      options = {:date => date, :assignment_id => assignment_id, :grader_id => grader_id}
      submissions_array = submissions_set(course, api_context, options)

      versions_hash = submissions_array.inject({}) do |memo, sub|
        memo[sub.id] = sub.versions.map do |version|
          hash = version.model.attributes.symbolize_keys
          if hash[:grader_id] && hash[:grader_id] > 0
            hash[:grader] = user_cache[hash[:grader_id]].name
            hash[:safe_grader_id] = hash[:grader_id]
          else
            hash[:grader] = default_grader.name
            hash[:safe_grader_id] = 0
          end
          hash[:assignment_name] = assignment.title
          hash[:student_user_id] = hash[:user_id]
          hash[:student_name] = user_cache[hash[:user_id]].name
          hash[:course_id] = course.id
          hash[:submission_id] = sub.id
          hash[:graded_on] = hash[:graded_at].in_time_zone.to_date if hash[:graded_at]
          hash[:current_grade] = sub.grade
          hash[:current_graded_at] = sub.graded_at
          hash[:current_grader] = sub.grader.try(:name) || default_grader.name
          hash
        end
        memo
      end

      versions_hash.inject([]) do |memo, (submission_id, versions)|
        prior = {}
        filtered_versions = versions.sort{|a,b| a[:updated_at] <=> b[:updated_at] }.each_with_object([]) do |version, new_array|
          if version[:score]
            if prior[:submission_id].nil? || prior[:score] != version[:score]
              if prior[:submission_id].nil?
                PREVIOUS_VERSION_ATTRS.each { |attr| version["previous_#{attr}".to_sym] = nil }
              elsif prior[:score] != version[:score]
                new_array.pop if prior[:graded_at].try(:to_date) == version[:graded_at].try(:to_date) && prior[:grader] == version[:grader]
                PREVIOUS_VERSION_ATTRS.each { |attr| version["previous_#{attr}".to_sym] = prior[attr] }
              end
              NEW_ATTRS.each { |attr| version["new_#{attr}".to_sym] = version[attr] }
              new_array << version.slice(*VALID_KEYS)
            end
          end
          prior.merge!(version.slice(:grade, :score, :graded_at, :grader, :submission_id))
        end

        memo << { :submission_id => submission_id, :versions => filtered_versions }
      end

    end

    def day_string_for(submission)
      graded_at = submission.graded_at
      return '' if graded_at.nil?
      graded_at.in_time_zone.to_date.as_json
    end

    def submissions_set(course, api_context, options = {})
      collection = ::Submission.for_course(course).scoped(:order => 'graded_at DESC')

      if options[:date]
        date = options[:date]
        collection = collection.scoped(:conditions => ["graded_at < ? and graded_at > ?", date.end_of_day, date.beginning_of_day])
      else
        collection = collection.scoped(:conditions => 'graded_at IS NOT NULL')
      end

      if assignment_id = options[:assignment_id]
        collection = collection.scoped_by_assignment_id(assignment_id)
      end

      if grader_id = options[:grader_id]
        if grader_id.to_s == '0'
          # yes, this is crazy.  autograded submissions have the grader_id of (quiz_id x -1)
          collection = collection.scoped(:conditions => 'submissions.grader_id <= 0')
        else
          collection = collection.scoped_by_grader_id(grader_id)
        end
      end

      api_context.paginate(collection)
    end


    private

    PREVIOUS_VERSION_ATTRS = [:grade, :graded_at, :grader]
    NEW_ATTRS = [:grade, :graded_at, :grader, :score]

    DEFAULT_GRADER = Struct.new(:name, :id)

    VALID_KEYS = [
        :assignment_id, :assignment_name, :attachment_id, :attachment_ids,
        :body, :course_id, :created_at, :current_grade, :current_graded_at,
        :current_grader, :grade_matches_current_submission, :graded_at,
        :graded_on, :grader, :grader_id, :group_id, :id, :new_grade,
        :new_graded_at, :new_grader, :previous_grade, :previous_graded_at,
        :previous_grader, :process_attempts, :processed, :published_grade,
        :published_score, :safe_grader_id, :score, :student_entered_score,
        :student_user_id, :submission_id, :student_name, :submission_type,
        :updated_at, :url, :user_id, :workflow_state
    ].freeze

    def default_grader
      @default_grader ||= DEFAULT_GRADER.new(I18n.t('gradebooks.history.graded_on_submission', 'Graded on submission'), 0)
    end

    def user_cache
      @user_cache ||= Hash.new{ |hash, user_id| hash[user_id] = ::User.find(user_id) }
    end

    def assignment_cache
      @assignment_cache ||= Hash.new{ |hash, assignment_id| hash[assignment_id] = ::Assignment.find(assignment_id) }
    end

    def update_graders_hash(hash, submission, api_context)
      grader = submission.grader || default_grader
      hash[grader.id] ||= {
        :name => grader.name,
        :id => grader.id,
        :assignments => {}
      }

      hash[grader.id][:assignments][submission.assignment_id] ||= begin
        assignment = assignment_cache[submission.assignment_id]
        assignment_json(assignment, api_context.user, api_context.session)
      end
    end

    def compress(hash, key)
      hash[key] = hash[key].values
    end

  end
end
