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

module AuthenticationMethods

  def authorized(*groups)
    authorized_roles = groups
    return true
  end

  def authorized_roles
    @authorized_roles ||= []
  end

  def consume_authorized_roles
    authorized_roles = []
  end

  def load_pseudonym_from_policy
    skip_session_save = false
    if verified = (policy_encoded = params['Policy']) &&
        (signature = params['Signature']) &&
        signature == Base64.encode64(OpenSSL::HMAC.digest(OpenSSL::Digest::Digest.new('sha1'), Attachment.shared_secret, policy_encoded)).gsub(/\n/, '')
      if session.to_hash.empty? && # if there's already some session data, defer to normal auth
          (policy = JSON.parse(Base64.decode64(policy_encoded)) rescue nil) &&
          policy['conditions'] &&
          (credential = policy['conditions'].detect{ |cond| cond.is_a?(Hash) && cond.has_key?("pseudonym_id") })
        skip_session_save = true
        @policy_pseudonym_id = credential['pseudonym_id']
      end
    end

    # so that we don't have to explicitly skip verify_authenticity_token
    params[self.class.request_forgery_protection_token] ||= form_authenticity_token if verified

    yield if block_given?
    session.destroy if skip_session_save
  end

  class AccessTokenError < Exception
  end

  def load_pseudonym_from_access_token
    return unless api_request? || params[:action] == 'oauth2_logout'

    auth_header = ActionController::HttpAuthentication::Basic.authorization(request)
    token_string = if auth_header.present? && (header_parts = auth_header.split(' ', 2)) && header_parts[0] == 'Bearer'
      header_parts[1]
    elsif params[:access_token].present?
      params[:access_token]
    end

    if token_string
      @access_token = AccessToken.authenticate(token_string)
      if !@access_token
        raise AccessTokenError
      end
      @current_user = @access_token.user
      #@current_pseudonym = @current_user.find_pseudonym_for_account(@domain_root_account, true)
      @current_pseudonym = @current_user.find_pseudonym_for_account(default_domain_root_account, true)
      unless @current_user && @current_pseudonym
        raise AccessTokenError
      end
      @access_token.used!
    end
  end

  def load_user
    @current_user = @current_pseudonym = nil

    load_pseudonym_from_access_token

    if !@current_pseudonym
      if @policy_pseudonym_id
        @current_pseudonym = Pseudonym.find_by_id(@policy_pseudonym_id)
      else
        @pseudonym_session = PseudonymSession.find
        @current_pseudonym = @pseudonym_session && @pseudonym_session.record
      end
      if params[:login_success] == '1' && !@current_pseudonym
        # they just logged in successfully, but we can't find the pseudonym now?
        # sounds like somebody hates cookies.
        return redirect_to(login_url(:needs_cookies => '1'))
      end
      @current_user = @current_pseudonym && @current_pseudonym.user

      if api_request?
        # only allow api_key to be used if basic auth was sent, not if they're
        # just using an app session
        # this basic auth support is deprecated and marked for removal in 2012
        if @pseudonym_session.try(:used_basic_auth?) && params[:api_key].present?
          Shard.default.activate { @developer_key = DeveloperKey.find_by_api_key(params[:api_key]) }
        end
        @developer_key || request.get? || form_authenticity_token == form_authenticity_param || form_authenticity_token == request.headers['X-CSRF-Token'] || raise(AccessTokenError)
      end
    end

    if @current_user && @current_user.unavailable?
      @current_pseudonym = nil
      @current_user = nil
    end

    if api_request? && !@current_user
      raise AccessTokenError
    end

    if @current_user && %w(become_user_id me become_teacher become_student).any? { |k| params.key?(k) }
      request_become_user = nil
      if params[:become_user_id]
        request_become_user = User.find_by_id(params[:become_user_id])
      elsif params.keys.include?('me')
        request_become_user = @current_user
      elsif params.keys.include?('become_teacher')
        course = Course.find(params[:course_id] || params[:id]) rescue nil
        teacher = course.teachers.first if course
        if teacher
          request_become_user = teacher
        else
          flash[:error] = I18n.t('lib.auth.errors.teacher_not_found', "No teacher found")
        end
      elsif params.keys.include?('become_student')
        course = Course.find(params[:course_id] || params[:id]) rescue nil
        student = course.students.first if course
        if student
          request_become_user = student
        else
          flash[:error] = I18n.t('lib.auth.errors.student_not_found', "No student found")
        end
      end

      if request_become_user && request_become_user.id != session[:become_user_id].to_i && request_become_user.can_masquerade?(@current_user, @domain_root_account)
        params_without_become = params.dup
        params_without_become.delete_if {|k,v| [ 'become_user_id', 'become_teacher', 'become_student', 'me' ].include? k }
        params_without_become[:only_path] = true
        session[:masquerade_return_to] = url_for(params_without_become)
        return redirect_to user_masquerade_url(request_become_user.id)
      end
    end

    as_user_id = api_request? && params[:as_user_id].presence
    as_user_id ||= session[:become_user_id]
    if as_user_id
      begin
        user = api_find(User, as_user_id)
      rescue ActiveRecord::RecordNotFound
      end
      if user && user.can_masquerade?(@current_user, @domain_root_account)
        @real_current_user = @current_user
        @current_user = user
        @real_current_pseudonym = @current_pseudonym
        @current_pseudonym = @current_user.find_pseudonym_for_account(@domain_root_account, true)
        logger.warn "#{@real_current_user.name}(#{@real_current_user.id}) impersonating #{@current_user.name} on page #{request.url}"
      elsif api_request?
        # fail silently for UI, but not for API
        render :json => {:errors => "Invalid as_user_id"}, :status => :unauthorized
        return false
      end
    end

    @current_user
  end
  private :load_user

  def require_user
    if @current_user && @current_pseudonym
      true
    else
      redirect_to_login
      false
    end
  end
  protected :require_user

  def store_location(uri=nil, overwrite=true)
    if overwrite || !session[:return_to]
      session[:return_to] = uri || request.request_uri
    end
  end
  protected :store_location

  def redirect_back_or_default(default)
    redirect_to(session[:return_to] || default)
    session.delete(:return_to)
  end
  protected :redirect_back_or_default

  def get_redirected_return_to_url
     return_to = session[:return_to] || root_url
     session.delete(:return_to)
     return_to
  end

  protected :get_redirected_return_to_url

  def redirect_to_referrer_or_default(default)
    redirect_to(:back)
  rescue ActionController::RedirectBackError
    redirect_to(default)
  end

  def redirect_to_login
    respond_to do |format|
      format.html {
        store_location
        flash[:warning] = I18n.t('lib.auth.errors.not_authenticated', "You must be logged in to access this page") unless request.path == '/'
        opts = {}
        opts[:canvas_login] = 1 if params[:canvas_login]
        redirect_to login_url(opts) # should this have :no_auto => 'true' ?
      }
      format.json { render :json => {:errors => {:message => I18n.t('lib.auth.authentication_required', "user authorization required")}}.to_json, :status => :unauthorized}
    end
  end

  # Reset the session, and copy the specified keys over to the new session.
  # Please consider the security implications of any keys you copy over.
  def reset_session_saving_keys(*keys)
    # can't use slice, because session has a different ctor than a normal hash
    saved = {}
    keys.each { |k| saved[k] = session[k] if session[k] }
    reset_session
    saved.each_pair { |k, v| session[k] = v }
  end

  def reset_session_for_login
    reset_session_saving_keys(:return_to, :oauth2, :confirm, :enrollment, :expected_user_id, :masquerade_return_to)
  end

  def initiate_delegated_login(current_host=nil)
    is_delegated = @domain_root_account.delegated_authentication? && !params[:canvas_login]
    is_cas = is_delegated && @domain_root_account.cas_authentication?
    is_saml = is_delegated && @domain_root_account.saml_authentication?
    if is_cas
      initiate_cas_login
      return true
    elsif is_saml

      if @domain_root_account.auth_discovery_url
        redirect_to @domain_root_account.auth_discovery_url
      else
        initiate_saml_login(current_host)
      end

      return true
    end
    false
  end

  def initiate_cas_login(cas_client = nil)
    reset_session_for_login
    config = { :cas_base_url => @domain_root_account.account_authorization_config.auth_base }
    cas_client ||= CASClient::Client.new(config)
    delegated_auth_redirect(cas_client.add_service_to_login_url(cas_login_url))
  end

  def initiate_saml_login(current_host=nil, aac=nil)
    reset_session_for_login
    aac ||= @domain_root_account.account_authorization_config
    settings = aac.saml_settings(current_host)
    request = Onelogin::Saml::AuthRequest.new(settings)
    forward_url = request.generate_request
    if aac.debugging? && !aac.debug_get(:request_id)
      aac.debug_set(:request_id, request.id)
      aac.debug_set(:to_idp_url, forward_url)
      aac.debug_set(:to_idp_xml, request.request_xml)
      aac.debug_set(:debugging, "Forwarding user to IdP for authentication")
    end
    delegated_auth_redirect(forward_url)
  end

  def delegated_auth_redirect(uri)
    redirect_to(delegated_auth_redirect_uri(uri))
  end

  def delegated_auth_redirect_uri(uri)
    uri
  end
end
