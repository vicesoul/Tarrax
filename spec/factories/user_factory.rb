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

def user_model(opts={})
  @user = factory_with_protected_attributes(User, valid_user_attributes.merge(opts))
end

def tie_user_to_account(user, opts={})
  user.account_users.create(:account => opts[:account] || Account.default, :membership_type => opts[:membership_type] || 'AccountAdmin')
end

def tie_user_to_user_account_association(user, opts={})
  UserAccountAssociation.create!(
    :user => user,
    :account => opts[:account] || Account.default,
    :enrollment_type => 'student',
    :source => 'created',
    :external => false,
    :job_number => 'code-001-001',
    :job_position => job_position_model,
    :tag_list => 'tag1,tag2,tag3',
    :state => 0
  )
end

def valid_user_attributes
  {
    :name => 'value for name',
  }
end
