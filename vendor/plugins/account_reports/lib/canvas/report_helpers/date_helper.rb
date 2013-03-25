#
# Copyright (C) 2012 - 2013 Instructure, Inc.
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

module Canvas::ReportHelpers::DateHelper

# This function will take a datetime or a datetime string and convert into iso8601 for the @account's timezone
# A string datetime needs to be in UTC
  def default_timezone_format(datetime, account=@account.root_account)
    if datetime.is_a? String
      datetime = Time.use_zone('UTC') do
        Time.zone.parse(datetime)
      end
    end
    if datetime
      datetime.in_time_zone(account.default_time_zone).iso8601
    else
      nil
    end
  end

# This function will take a datetime string and parse into UTC from the @account's timezone
  def account_time_parse(datetime, account=@account.root_account)
    Time.use_zone(account.default_time_zone) do
      Time.zone.parse datetime.to_s rescue nil
    end
  end
end
