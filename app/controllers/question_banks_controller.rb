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

class QuestionBanksController < ApplicationController
  before_filter :require_context, :except => :bookmark
  add_crumb( proc { I18n.t('jxb.question_banks', 'Question Banks') }, :except => :bookmark ) { |c| c.send :named_context_url, c.instance_variable_get("@context"), :context_question_banks_url }

  include Api::V1::Outcome

  def index
    if @context == @current_user || authorized_action(@context, @current_user, :manage_assignments)
      @question_banks = @context.assessment_question_banks.active
      if params[:include_bookmarked] == '1'
        @question_banks += @current_user.assessment_question_banks.active
      end
      if params[:inherited] == '1' && @context != @current_user && @context.grants_right?(@current_user, nil, :read_question_banks) 
        @question_banks += @context.inherited_assessment_question_banks
      end
      @question_banks = @question_banks.select{|b| b.grants_right?(@current_user, nil, :manage) } if params[:managed] == '1'
      @question_banks = @question_banks.uniq.sort_by{|b| b.title || "zzz" }
      respond_to do |format|
        format.html
        format.json { render :json => @question_banks.to_json(:methods => [:cached_context_short_name, :assessment_question_count]) }
      end
    end
  end
  
  def questions
    find_bank(params[:question_bank_id], params[:inherited] == '1') do
      @questions = @bank.assessment_questions.active.paginate(:per_page => 50, :page => params[:page])
      render :json => {:pages => @questions.total_pages, :questions => @questions}.to_json
    end
  end
  
  def reorder
    @bank = @context.assessment_question_banks.find(params[:question_bank_id])
    if authorized_action(@bank, @current_user, :update)
      @bank.assessment_questions.active.first.update_order(params[:order].split(','))
      render :json => {:reorder => true}
    end
  end

  def show
    @bank = @context.assessment_question_banks.find(params[:id])
    js_env :ROOT_OUTCOME_GROUP => outcome_group_json(@context.root_outcome_group, @current_user, session)

    add_crumb(@bank.title)
    if authorized_action(@bank, @current_user, :read)
      @alignments = @bank.learning_outcome_alignments.sort_by{|a| a.learning_outcome.short_description.downcase }
      @questions = @bank.assessment_questions.active.paginate(:per_page => 50, :page => 1)
    end
  end
  
  def move_questions
    @bank = @context.assessment_question_banks.find(params[:question_bank_id])
    @new_bank = AssessmentQuestionBank.find(params[:assessment_question_bank_id])
    if authorized_action(@bank, @current_user, :update) && authorized_action(@new_bank, @current_user, :manage)
      ids = []
      params[:questions].each do |key, value|
        ids << key.to_i if value != '0' && key.to_i != 0
      end
      @questions = @bank.assessment_questions.scoped(:conditions => { :id => ids})
      if params[:move] != '1'
        attributes = @questions.columns.map(&:name) - %w{id created_at updated_at assessment_question_bank_id}
        connection = @questions.connection
        attributes = attributes.map { |attr| connection.quote_column_name(attr) }
        now = connection.quote(Time.now.utc)
        connection.execute(
            "INSERT INTO assessment_questions (#{(%w{assessment_question_bank_id created_at updated_at} + attributes).join(', ')})" +
            @questions.construct_finder_sql(:select => ([@new_bank.id, now, now] + attributes).join(', ')))
      else
        @questions.update_all(:assessment_question_bank_id => @new_bank.id)
      end
      render :json => {}
    end
  end
  
  def create
    if authorized_action(@context.assessment_question_banks.new, @current_user, :create)
      @bank = @context.assessment_question_banks.build(params[:assessment_question_bank])
      respond_to do |format|
        if @bank.save
          @bank.bookmark_for(@current_user)
          flash[:notice] = t :bank_success, "Question bank successfully created!"
          format.html { redirect_to named_context_url(@context, :context_question_banks_url) }
          format.json { render :json => @bank.to_json }
        else
          flash[:error] = t :bank_fail, "Question bank failed to create."
          format.html { redirect_to named_context_url(@context, :context_question_banks_url) }
          format.json { render :json => @bank.errors.to_json, :status => :bad_request }
        end
      end
    end
  end
  
  def bookmark
    @bank = AssessmentQuestionBank.find(params[:question_bank_id])

    if params[:unbookmark] == "1"
      render :json => @bank.bookmark_for(@current_user, false).to_json
    elsif authorized_action(@bank, @current_user, :update)
      render :json => @bank.bookmark_for(@current_user).to_json
    end
  end
  
  def update
    @bank = @context.assessment_question_banks.find(params[:id])
    if authorized_action(@bank, @current_user, :update)
      if @bank.update_attributes(params[:assessment_question_bank])
        @bank.reload
        render :json => @bank.to_json(:include => {:learning_outcome_alignments => {:include => :learning_outcome}})
      else
        render :json => @bank.errors.to_json, :status => :bad_request
      end
    end
  end
  
  def destroy
    @bank = @context.assessment_question_banks.find(params[:id])
    if authorized_action(@bank, @current_user, :delete)
      @bank.destroy
      render :json => @bank.to_json
    end
  end
end
