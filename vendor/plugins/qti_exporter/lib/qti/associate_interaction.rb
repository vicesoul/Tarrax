module Qti
class AssociateInteraction < AssessmentItemConverter
  include Canvas::Migration::XMLHelper
  
  def initialize(opts)
    super(opts)
    @question[:matches] = []
    @question[:question_type] = 'matching_question'
    # to mark whether it's bb8/vista/respondus_matching if needed
    @custom_type = opts[:custom_type]
  end

  def parse_question_data
    if @doc.at_css('associateInteraction')
      match_map = {}
      get_all_matches_with_interaction(match_map)
      get_all_answers_with_interaction(match_map)
      check_for_meta_matches
    elsif node = @doc.at_css('matchInteraction')
      get_all_match_interaction(node)
    elsif @custom_type == 'respondus_matching'
      get_respondus_answers
      get_respondus_matches
    elsif @custom_type == 'canvas_matching'
      match_map = {}
      get_canvas_matches(match_map)
      get_canvas_answers(match_map)
      attach_feedback_values(@question[:answers])
    else
      get_all_matches_from_body
      get_all_answers_from_body
    end
    
    get_feedback()
    ensure_correct_format
    
    @question
  end
  
  private
  
  def ensure_correct_format
    @question[:answers].each do |answer|
      answer[:left] = answer[:text] if answer[:text].present?
      answer[:left_html] = answer[:html] if answer[:html].present?
      if answer[:match_id]
        if @question[:matches] && match = @question[:matches].find{|m|m[:match_id] == answer[:match_id]}
          answer[:right] = match[:text]
        end
      end
    end
  end
  
  def get_canvas_matches(match_map)
    if ci = @doc.at_css('choiceInteraction')
      ci.css('simpleChoice').each do |sc|
        match = {}
        @question[:matches] << match
        match_map[sc['identifier']] = match
        if sc['identifier'] =~ /(\d+)/
          match[:match_id] = $1.to_i
        else
          match[:match_id] = unique_local_id
        end
        match[:text] = sc.text.strip
      end
    end
  end
  
  def get_canvas_answers(match_map)
    answer_map = {}
    @doc.css('choiceInteraction').each do |ci|
      answer = {}
      @question[:answers] << answer
      answer_map[ci['responseIdentifier']] = answer
      extract_answer!(answer, ci.at_css('prompt'))
      answer[:id] = unique_local_id
    end
    
    # connect to match
    @doc.css('responseIf, responseElseIf').each do |r_if|
      answer_mig_id = nil
      match_mig_id = nil
      if match = r_if.at_css('match')
        answer_mig_id = get_node_att(match, 'variable', 'identifier')
        match_mig_id = match.at_css('baseValue[baseType=identifier]').text rescue nil
      end
      if answer = answer_map[answer_mig_id]
        answer[:feedback_id] = get_feedback_id(r_if)
        if r_if.at_css('setOutcomeValue[identifier=SCORE] sum') && match = match_map[match_mig_id]
          answer[:match_id] = match[:match_id]
        end
      end
    end
  end

  def get_respondus_answers
    @doc.css('choiceInteraction').each do |a|
      answer = {}
      @question[:answers] << answer
      extract_answer!(answer, a.at_css('prompt'))
      answer[:id] = unique_local_id
      answer[:migration_id] = a['responseIdentifier']
      answer[:comments] = ""
      #answer[:match_id] = @question[:matches][i][:match_id]
    end
  end

  def get_respondus_matches
    @question[:answers].each do |answer|
      @doc.css('responseIf, responseElseIf').each do |r_if|
        if r_if.at_css("match variable[identifier=#{answer[:migration_id]}]") && r_if.at_css('setOutcomeValue[identifier$=_CORRECT]')
          match = {}
          @question[:matches] << match
          migration_id = r_if.at_css('match baseValue').text
          match[:text] = clear_html((@doc.at_css("simpleChoice[identifier=#{migration_id}] p") || @doc.at_css("simpleChoice[identifier=#{migration_id}] div")).text)
          match[:match_id] = unique_local_id
          answer[:match_id] = match[:match_id]
          answer.delete :migration_id
          break
        end
      end
    end
    all_matches = @doc.css('simpleChoice p, simpleChoice div').map { |e| clear_html(e.text) }
    distractors = all_matches.delete_if { |m| @question[:matches].any? { |qm| qm[:text] == m } }
    distractors.uniq.each do |distractor|
      @question[:matches] << {
        :text => distractor,
        :match_id => unique_local_id,
      }
    end
  end

  def get_all_matches_from_body
    if matches = @doc.at_css('div.RIGHT_MATCH_BLOCK')
      matches.css('div').each do |m|
        match = {}
        @question[:matches] << match
        match[:text] = clear_html(m.text.strip)
        match[:match_id] = unique_local_id
      end
    end
  end
  
  def get_all_answers_from_body
    @doc.css('div.RESPONSE_BLOCK div').each_with_index do |a, i|
      answer = {}
      @question[:answers] << answer
      extract_answer!(answer, a)
      answer[:id] = unique_local_id 
      answer[:comments] = ""
      answer[:match_id] = @question[:matches][i][:match_id]
    end
  end
  
  def get_all_matches_with_interaction(match_map)
    if matches = @doc.at_css('associateInteraction')
      matches.css('simpleAssociableChoice').each do |m|
        match = {}
        @question[:matches] << match
        extract_answer!(match, m)
        match[:match_id] = unique_local_id
        match_map[match[:text]] = match[:match_id]
        match_map[m['identifier']] = match[:match_id]
      end
    end
  end
  
  def get_all_answers_with_interaction(match_map)
    @doc.css('associateInteraction').each do |a|
      answer = {}
      @question[:answers] << answer
      extract_answer!(answer, a.at_css('prompt'))
      answer[:id] = unique_local_id 
      answer[:comments] = ""
      
      if option = a.at_css('simpleAssociableChoice[identifier^=MATCH]')
        answer[:match_id] = match_map[option.text.strip]
      elsif resp_id = a['responseIdentifier']
        @doc.css("match variable[identifier=#{resp_id}]").each do |variable|
          match = variable.parent
          response_if = match.parent
          if response_if.name =~ /response(Else)?If/
            if response_if.at_css('setOutcomeValue[identifier$=_CORRECT]')
              match_id = get_node_val(match, 'baseValue', '').strip
              answer[:match_id] = match_map[match_id]
              break
            end
          end
        end
      end
    end
  end
  
  # Replaces the matches with their full-text instead of a,b,c/1,2,3/etc.
  def check_for_meta_matches
    if long_matches = @doc.search('instructureMetadata matchingMatch')
      @question[:matches].each_with_index do |match, i|
        match[:text] = long_matches[i].text.strip.gsub(/ +/, " ") if long_matches[i]
      end
      if long_matches.size > 0 && long_matches.size != @question[:matches].size
        @question[:qti_warning] = "The matching options for this question may have been incorrectly imported."
      end
    end
  end

  def get_all_match_interaction(interaction_node)
    answer_map={}
    interaction_node.at_css('simpleMatchSet').css('simpleAssociableChoice').each do |node|
      answer = {}
      extract_answer!(answer, node)
      answer[:id] = unique_local_id
      @question[:answers] << answer
      id = node['identifier']
      answer_map[id] = answer
    end

    match_map = {}
    interaction_node.css('simpleMatchSet').last.css('simpleAssociableChoice').each do |node|
      match = {}
      match[:text] = node.text.strip
      match[:match_id] = unique_local_id
      @question[:matches] << match
      id = node['identifier']
      match_map[id] = match
    end

    #Check if there are correct answers explicitly specified
    @doc.css('correctResponse > value').each do |match|
      answer_id, match_id = match.text.split
      if answer = answer_map[answer_id.strip] and m = match_map[match_id.strip]
        answer[:match_id] = m[:match_id]
      end
    end
  end

  def extract_answer!(answer, node)
    text, html = detect_html(node)
    answer[:text] = text
    if html.present?
      answer[:html] = html
    end
  end

end
end
