class SalesController < ApplicationController
  PER_PAGE = 25

  before_filter :require_view_sales_accounts
  def require_view_sales_accounts
    require_site_admin_with_permission(:view_error_reports)
  end

  def index
    @account_users = AccountUser.root_account_users
    @account_users = @account_users.paginate(:page => params[:page], :per_page => PER_PAGE)
  end

end
