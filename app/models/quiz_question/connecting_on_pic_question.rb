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

class QuizQuestion::ConnectingOnPicQuestion < QuizQuestion::Base
  ANSWER_REG = /ball-[0-9]+/

  def total_answer_parts
    @question_data[:answers].inject(0) do |sum, a|
      sum + a['right'].scan(/ball/).size
    end
  end


  def correct_answer_parts(user_answer)
    total_answers = 0
    correct_answers = 0
    @incorrect_answers = 0

    @question_data[:answers].each do |answer|
      %w(left).each do |position|
        answer_data = user_answer["answer_#{answer[:id]}_#{position}"].to_s


        if answer_data.present?
          user_answer_array = answer_data.scan(ANSWER_REG)
          total_answers += user_answer_array.size

          answer_array = answer["right"].scan(ANSWER_REG)

          correct_answers += (answer_array & user_answer_array).size
          @incorrect_answers += (user_answer_array - answer_array).size
        end
        user_answer.answer_details["answer_#{answer[:id]}_#{position}".to_sym] = answer_data
      end
    end

    return nil if total_answers == 0

    correct_answers
  end

  def incorrect_answer_parts(user_answer)
    @incorrect_answers # calculated in `correct_answer_parts`
  end
end
