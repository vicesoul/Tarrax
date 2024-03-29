class AssignmentCell < ApplicationCell

  def index

    @assignments = context.active_assignments_of_courses get_widget_courses

    @has_submited_assignment_ids = current_user.submissions.map{ |s| s.assignment_id } if current_user
    format_contexts(@assignments)

    prepend_view_path Jxb::Theme.widget_path(theme)

    render
  end

end

