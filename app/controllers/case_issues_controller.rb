class CaseIssuesController < ApplicationController

  before_filter :get_context, :set_active_tab
  before_filter :get_bread_crumb, :only => [:index, :show, :new, :edit]
  before_filter :auth_case_as_student, :except => [:review_case_issue]
  before_filter :auth_case_as_teacher, :only => [:review_case_issue]
  before_filter(:only => [:edit, :update, :destroy]) do |c|
    c.__send__(:auth_case_as_self) do 
      @case_issue = CaseIssue.find(c.params[:id])
      c.instance_variable_set(:@case_issue, @case_issue)
      c.__send__(:redirect_to, c.__send__(:course_case_issues_path)) unless @case_issue.user.id == c.instance_variable_get(:@current_user).id
    end
    
  end

  # GET /case_issues
  # GET /case_issues.xml
  def index
    case_repostory_id = Course.find(params[:context_id]).case_repostory.id
    search_params =
      if params[:search].nil?
        {:case_repostory_id_equals => case_repostory_id}
      else
        params[:search].merge!(:case_repostory_id_equals => case_repostory_id)
      end
    @search = CaseIssue.search(search_params)
    @case_issues = @search.paginate(:page => params[:page], :per_page => 25, :total_entries => @search.size)

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @case_issues }
    end
  end

  # GET /case_issues/1
  # GET /case_issues/1.xml
  def show
    @case_issue = CaseIssue.find(params[:id])

    respond_to do |format|
      format.html # show.html.erb
      format.xml  { render :xml => @case_issue }
    end
  end

  # GET /case_issues/new
  # GET /case_issues/new.xml
  def new
    @case_issue = Course.find(params[:context_id]).root_account.case_tpls.empty? ? CaseIssue.find_or_init_case_tpl : CaseIssue.new

    respond_to do |format|
      format.html # new.html.erb
      format.xml  { render :xml => @case_issue }
    end
  end

  # GET /case_issues/1/edit
  def edit
  end

  # POST /case_issues
  # POST /case_issues.xml
  def create
    @case_issue = CaseIssue.new(params[:case_issue])

    tpl = @case_issue.build_case_tpl(:name => 'Default case issue template', :user_id => @current_user.id)
    params[:case_tpl_widget].each { |widget| tpl.case_tpl_widgets.build(widget) }
    respond_to do |format|
      if @case_issue.save
        format.html { redirect_to(course_case_issues_url, :notice => 'CaseIssue was successfully created.') }
        format.xml  { render :xml => @case_issue, :status => :created, :location => course_case_issues_url }
      else
        format.html { render :action => "new" }
        format.xml  { render :xml => @case_issue.errors, :status => :unprocessable_entity }
      end
    end
  end

  def submit_case_issue
    issue = CaseIssue.find(params[:case_issue_id])
    if issue.user.id == @current_user.id
      render :json => issue.submit.to_json
    else
      render :json => false
    end
  end

  def review_case_issue
    issue = CaseIssue.find(params[:case_issue_id])
    if issue.awaiting_review? && %w[accept reject].include?(params[:review_result])
      issue.review
      render :json => issue.__send__(params[:review_result]).to_json
    else
      render :json => false
    end
  end

  def apply_case_issue
    result = false
    issue = CaseIssue.find(params[:case_issue_id])
    if issue.state == :accepted  
      CaseSolution.transaction do
        solution = CaseSolution.new(
          :case_issue => issue,
          :user => @current_user,
          :group_discuss => params[:group_discuss] == nil ? false : params[:group_discuss]
        )
        result = solution.save
        if result && solution.group_discuss
          group = @context.groups.create(:name => params[:group_name])
          group.group_memberships.create(:user => @current_user, :moderator => false)
        end
        solution.execute if result
      end
      render :json => result.to_json
    else
      render :json => false
    end  
  end

  # PUT /case_issues/1
  # PUT /case_issues/1.xml
  def update
    result = false
    @case_issue = CaseIssue.find(params[:id])
    CaseIssue.transaction do 
      @case_issue.case_tpl.case_tpl_widgets.destroy_all unless @case_issue.case_tpl.case_tpl_widgets.empty?
      params[:case_tpl_widget].each {|w| @case_issue.case_tpl.case_tpl_widgets.build(w)} unless params[:case_tpl_widget].nil?
      result = @case_issue.update_attributes(params[:case_issue]) && @case_issue.case_tpl.save
    end

    respond_to do |format|
      if result   
        format.html { redirect_to(course_case_issues_url, :notice => 'CaseIssue was successfully updated.') }
        format.xml  { head :ok }
      else
        format.html { render :action => "edit" }
        format.xml  { render :xml => @case_issue.errors, :status => :unprocessable_entity }
      end
    end
  end

  # DELETE /case_issues/1
  # DELETE /case_issues/1.xml
  def destroy
    @case_issue.destroy if @case_issue.new?

    respond_to do |format|
      format.html { redirect_to(course_case_issues_url) }
      format.xml  { head :ok }
    end
  end
  #
  private

  def set_active_tab
    @active_tab = "case_repostory"
  end

  def get_bread_crumb
    add_crumb(t('', 'Case Issues'), course_case_issues_path(@context))
  end

end
