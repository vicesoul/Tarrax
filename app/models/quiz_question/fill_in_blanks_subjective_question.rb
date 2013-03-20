#
# Copyright (C) 2012 Instructure, Inc.
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

class QuizQuestion::FillInBlanksSubjectiveQuestion < QuizQuestion::Base
  def requires_manual_scoring?(user_answer)
    true
  end

  def correct_answer_parts(user_answer)
    config = Instructure::SanitizeField::SANITIZE
    user_answer.answer_text.each do |t|
      t = Sanitize.clean(t, config) || ""
    end
    nil
  end
end
