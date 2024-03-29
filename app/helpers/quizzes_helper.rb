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

module QuizzesHelper
  def needs_unpublished_warning?(quiz=@quiz)
    !quiz.available? || quiz.unpublished_changes?
  end

  def unpublished_quiz_warning
    I18n.t("#quizzes.warnings.unpublished_quiz",
      '*This quiz is unpublished* Only teachers can see the quiz until ' +
      'it is published.',
      :wrapper => '<strong class=unpublished_quiz_warning>\1</strong>')
  end

  def unpublished_changes_warning
    I18n.t("#quizzes.warnings.unpublished_changes",
      '*You have made unpublished changes to this quiz.* '+
      'These changes will not appear for students until you publish or ' +
      'republish the quiz.',
      :wrapper => '<strong class=unpublished_quiz_warning>\1</strong>')
  end

  def render_score(score, precision=2)
    if score.nil?
      '_'
    else
      score.to_f.round(precision).to_s
    end
  end

  def render_quiz_type(quiz_type)
    case quiz_type
    when "practice_quiz"
      I18n.t('#quizzes.practice_quiz', "Practice Quiz")
    when "assignment"
      I18n.t('#quizzes.graded_quiz', "Graded Quiz")
    when "graded_survey"
      I18n.t('#quizzes.graded_survey', "Graded Survey")
    when "survey"
      I18n.t('#quizzes.ungraded_survey', "Ungraded Survey")
    end
  end

  def render_score_to_keep(quiz_scoring_policy)
    case quiz_scoring_policy
    when "keep_highest"
      I18n.t('#quizzes.keep_highest', 'Highest')
    when "keep_latest"
      I18n.t('#quizzes.keep_latest', 'Latest')
    end
  end

  def render_show_responses(quiz_hide_results)
    # "Let Students See Their Quiz Responses?"
    case quiz_hide_results
    when "always"
      I18n.t('#options.no', "No")
    when "until_after_last_attempt"
      I18n.t('#quizzes.after_last_attempt', "After Last Attempt")
    when nil
      I18n.t('#quizzes.always', "Always")
    end
  end

  def render_unsubmitted_students(student_count)
    I18n.t('#quizzes.headers.unsubmitted_students_count',
      { :one => "1 student hasn't taken the survey",
        :other => "%{count} students haven't taken the survey" },
      { :count => student_count })
  end

  QuestionType = Struct.new(:question_type,
                          :entry_type,
                          :display_answers,
                          :answer_type,
                          :multiple_sets,
                          :unsupported
                         )

  def answer_type(question)
    return QuestionType.new unless question
    @answer_types_lookup ||= {
      "multiple_choice_question" => OpenObject.new({
        :question_type => "multiple_choice_question",
        :entry_type => "radio",
        :display_answers => "multiple",
        :answer_type => "select_answer"
      }),
      "true_false_question" => OpenObject.new({
        :question_type => "true_false_question",
        :entry_type => "radio",
        :display_answers => "multiple",
        :answer_type => "select_answer"
      }),
      "short_answer_question" => OpenObject.new({
        :question_type => "short_answer_question",
        :entry_type => "text_box",
        :display_answers => "single",
        :answer_type => "select_answer"
      }),
      "essay_question" => OpenObject.new({
        :question_type => "essay_question",
        :entry_type => "textarea",
        :display_answers => "single",
        :answer_type => "text_answer"
      }),
      "fill_in_blanks_subjective_question" => OpenObject.new({
        :question_type => "fill_in_blanks_subjective_question",
        :entry_type => "multiple_textarea",
        :display_answers => "single",
        :answer_type => "text_answer"
      }),
      "paint_question" => OpenObject.new({
       :question_type => "paint_question",
       :entry_type => "textarea",
       :display_answers => "single",
       :answer_type => "text_answer"
      }),
      "connecting_lead_question" => OpenObject.new({
       :question_type => "connecting_lead_question",
       :entry_type => "connecting_lead",
       :display_answers => "multiple",
       :answer_type => "connecting_lead_answer"      # view/quizzes/_multi_answer.html.erb
      }),
      "connecting_on_pic_question" => OpenObject.new({
       :question_type => "connecting_on_pic_question",
       :entry_type => "connecting_on_pic",
       :display_answers => "multiple",
       :answer_type => "connecting_on_pic_answer"      # view/quizzes/_multi_answer.html.erb
      }),
      "matching_question" => OpenObject.new({
        :question_type => "matching_question",
        :entry_type => "matching",
        :display_answers => "multiple",
        :answer_type => "matching_answer"
      }),
      "missing_word_question" => OpenObject.new({
        :question_type => "missing_word_question",
        :entry_type => "select",
        :display_answers => "multiple",
        :answer_type => "select_answer"
      }),
      "numerical_question" => OpenObject.new({
        :question_type => "numerical_question",
        :entry_type => "numerical_text_box",
        :display_answers => "single",
        :answer_type => "numerical_answer"
      }),
      "calculated_question" => OpenObject.new({
        :question_type => "calculated_question",
        :entry_type => "numerical_text_box",
        :display_answers => "single",
        :answer_type => "numerical_answer"
      }),
      "multiple_answers_question" => OpenObject.new({
        :question_type => "multiple_answers_question",
        :entry_type => "checkbox",
        :display_answers => "multiple",
        :answer_type => "select_answer"
      }),
      "fill_in_multiple_blanks_question" => OpenObject.new({
        :question_type => "fill_in_multiple_blanks_question",
        :entry_type => "text_box",
        :display_answers => "multiple",
        :answer_type => "select_answer",
        :multiple_sets => true
      }),
      "multiple_dropdowns_question" => OpenObject.new({
        :question_type => "multiple_dropdowns_question",
        :entry_type => "select",
        :display_answers => "none",
        :answer_type => "select_answer",
        :multiple_sets => true
      }),
      "drag_and_drop_question" => OpenObject.new({
        :question_type => "drag_and_drop_question",
        :entry_type => "select",
        :display_answers => "none",
        :answer_type => "select_answer",
        :multiple_sets => true
      }),
      "other" =>  OpenObject.new({
        :question_type => "text_only_question",
        :entry_type => "none",
        :display_answers => "none",
        :answer_type => "none"
      })
    }
    res = @answer_types_lookup[question[:question_type]] || @answer_types_lookup["other"]
    if res.question_type == "text_only_question"
      res.unsupported = question[:question_type] != "text_only_question"
    end
    res
  end

  # Build the question-level comments. Lists in the order of :correct_comments, :incorrect_comments, :neutral_comments.
  # ==== Arguments
  # * <tt>user_answer</tt> - The user_answer hash.
  # * <tt>question</tt> - The question hash.
  def question_comment(user_answer, question)
    correct_text   = (hash_get(user_answer, :correct) == true) ? comment_get(question, :correct_comments) : nil
    incorrect_text = (hash_get(user_answer, :correct) == false) ? comment_get(question, :incorrect_comments) : nil
    neutral_text   = (hash_get(question, :neutral_comments).present?) ? comment_get(question, :neutral_comments) : nil

    text = []
    text << content_tag(:p, correct_text, {:class => 'correct_comments'}) if correct_text.present?
    text << content_tag(:p, incorrect_text, {:class => 'incorrect_comments'}) if incorrect_text.present?
    text << content_tag(:p, neutral_text, {:class => 'neutral_comments'}) if neutral_text.present?
    if text.empty?
      ''
    else
      content_tag(:div, text.join('').html_safe, {:class => 'quiz_comment'})
    end
  end

  def comment_get(hash, field)
    if html = hash_get(hash, "#{field}_html".to_sym)
      raw(html)
    else
      hash_get(hash, field)
    end
  end

  def fill_in_multiple_blanks_question(options)
    question = hash_get(options, :question)
    answers  = hash_get(options, :answers).dup
    answer_list = hash_get(options, :answer_list)
    res      = user_content hash_get(question, :question_text)
    readonly_markup = hash_get(options, :editable) ? ' />' : 'readonly="readonly" />'
    # If given answer list, insert the values into the text inputs for displaying user's answers.
    if answer_list && !answer_list.empty?
      index  = 0
      res.gsub %r{<input.*?name=['"](question_.*?)['"].*?/>} do |match|
        a = h(answer_list[index])
        index += 1
        #  Replace the {{question_BLAH}} template text with the user's answer text.
        match.sub(/\{\{question_.*?\}\}/, a).
          # Match on "/>" but only when at the end of the string and insert "readonly" if set to be readonly
          sub(/\/\>\Z/, readonly_markup)
      end
    else
      answers.delete_if { |k, v| !k.match /^question_#{hash_get(question, :id)}/ }
      answers.each { |k, v| res.sub! /\{\{#{k}\}\}/, v }
      res.gsub /\{\{question_[^}]+\}\}/, ""
    end
    end

  def fill_in_blanks_subjective_question(options)
    question = hash_get(options, :question)
    answers  = hash_get(options, :answers).dup
    answer_list = hash_get(options, :answer_list)
    res      = user_content hash_get(question, :question_text)
    readonly_markup = hash_get(options, :editable) ? ' />' : 'readonly="readonly" />'
    # If given answer list, insert the values into the text inputs for displaying user's answers.
    if answer_list && !answer_list.empty?
      index  = 0
      res.gsub %r{<input.*?name=['"](question_.*?)['"].*?/>} do |match|
        a = answer_list[index]
        index += 1
        #  Replace the {{question_BLAH}} template text with the user's answer text.
        match.sub(/\{\{question_.*?\}\}/, a.to_s).
          # Match on "/>" but only when at the end of the string and insert "readonly" if set to be readonly
          sub(/\/\>\Z/, readonly_markup)
      end
    else
      answers.delete_if { |k, v| !k.match /^question_#{hash_get(question, :id)}/ }
      answers.each { |k, v| res.sub! /\{\{#{k}\}\}/, v }
      res.gsub /\{\{question_[^}]+\}\}/, ""
    end
  end

  def multiple_dropdowns_question(options)
    question = hash_get(options, :question)
    answers  = hash_get(options, :answers)
    answer_list = hash_get(options, :answer_list)
    res      = user_content hash_get(question, :question_text)
    index  = 0
    res.gsub %r{<select.*?name=['"](question_.*?)['"].*?>.*?</select>} do |match|
      if answer_list && !answer_list.empty?
        a = answer_list[index]
        index += 1
      else
        a = hash_get(answers, $1)
      end
      match.sub(%r{(<option.*?value=['"]#{ERB::Util.h(a)}['"])}, '\\1 selected')
    end
  end

  def drag_and_drop_question(options)
    question = hash_get(options, :question)
    answers  = hash_get(options, :answers)
    answer_list = hash_get(options, :answer_list)
    res      = user_content hash_get(question, :question_text)

    user_answers = {}
    res.scan(%r{(<option value='(\d+)'>.*?</option>)}) {|w| user_answers.merge!($2 => $1) }
    user_answers.each do |k,v|
      user_answers[k] = v.sub(%r{(<option.*?)>}, '\\1 selected>')
    end

    index  = 0
    res.gsub %r{<select.*?name=['"](question_.*?)['"].*?>.*?</select>} do |match|
      if answer_list && !answer_list.empty?
        a = answer_list[index]
        index += 1
      else
        a = hash_get(answers, $1)
      end
      match.sub(%r{(<select.*?>).*?(</select>)}, "\\1#{user_answers[a]}\\2")
    end
  end

  def duration_in_minutes(duration_seconds)
    if duration_seconds < 60
      duration_minutes = 0
    else
      duration_minutes = (duration_seconds / 60).round
    end
    I18n.t("quizzes.helpers.duration_in_minutes",
      { :zero => "less than 1 minute",
        :one => "1 minute",
        :other => "%{count} minutes" },
      :count => duration_minutes)
  end

  def score_out_of_points_possible(score, points_possible, options={})
    options.reverse_merge!({ :precision => 2 })
    score_html = \
      if options[:id] or options[:class] or options[:style] then
        content_tag('span',
          render_score(score, options[:precision]), 
          options.slice(:class, :id, :style))
      else
        render_score(score, options[:precision])
      end
    I18n.t("quizzes.helpers.score_out_of_points_possible", "%{score} out of %{points_possible}",
        :score => score_html,
        :points_possible => render_score(points_possible, options[:precision]))
  end

  def link_to_take_quiz(link_body, opts={})
    opts = opts.with_indifferent_access
    class_array = (opts['class'] || "").split(" ")
    class_array << 'element_toggler' if @quiz.cant_go_back?
    opts['class'] = class_array.compact.join(" ")
    opts['aria-controls'] = 'js-sequential-warning-dialogue' if @quiz.cant_go_back?
    opts['data-method'] = 'post' unless @quiz.cant_go_back?
    link_to(link_body, take_quiz_url, opts)
  end

  def take_quiz_url
    user_id = @current_user && @current_user.id
    polymorphic_path([@context, @quiz, :take], :user_id => user_id)
  end

  def link_to_take_or_retake_poll(opts={})
    if @submission && !@submission.settings_only?
      link_to_retake_poll(opts)
    else
      link_to_take_poll(opts)
    end
  end

  def link_to_take_poll(opts={})
    link_to_take_quiz(take_poll_message, opts)
  end

  def link_to_retake_poll(opts={})
    link_to_take_quiz(retake_poll_message, opts)
  end

  def link_to_resume_poll(opts = {})
    link_to_take_quiz(resume_poll_message, opts)
  end

  def take_poll_message(quiz=@quiz)
    quiz.survey? ?
      t('#quizzes.links.take_the_survey', 'Take the Survey') :
      t('#quizzes.links.take_the_quiz', 'Take the Quiz')
  end

  def retake_poll_message(quiz=@quiz)
    quiz.survey? ?
      t('#quizzes.links.take_the_survey_again', 'Take the Survey Again') :
      t('#quizzes.links.take_the_quiz_again', 'Take the Quiz Again')
  end

  def resume_poll_message(quiz=@quiz)
    quiz.survey? ?
      t('#quizzes.links.resume_survey', 'Resume Survey') :
      t('#quizzes.links.resume_quiz', 'Resume Quiz')
  end

  def score_to_keep_message(quiz=@quiz)
    quiz.scoring_policy == "keep_highest" ?
      t('#quizzes.links.will_keep_highest_score', "Will keep the highest of all your scores") :
      t('#quizzes.links.will_keep_latest_score', "Will keep the latest of all your scores")
  end

  def get_answer_left(hash, id)
    get_answer(hash, "#{id}_left")
  end

  def get_answer_right(hash, id)
    get_answer(hash, "#{id}_right")
  end

  def get_answer(hash, id)
    hash_get(hash, "answer_#{id}").to_i
  end

  def get_question_answer_left(hash, qid, aid)
    hash_get(hash, "question_#{qid}_answer_#{aid}_left") || ''
  end

  def get_question_answer_right(hash, qid, aid)
    hash_get(hash, "question_#{qid}_answer_#{aid}_right") || '' 
  end

end
