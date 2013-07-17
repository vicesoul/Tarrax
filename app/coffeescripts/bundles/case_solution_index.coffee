

require [
  'jquery'
  'jqueryui/dialog'
  'jqueryui/easyDialog'
], ($) ->

  $(document).ready(->
    $('.solution-submit').bind('click', ->
      _this = this
      $('<div></div>').easyDialog({
        content: '您确定要提交该案例解决方案吗？'
        confirmButtonClass: 'btn-primary'
        confirmCallback: ->
          $.get(_this.href, (data)->
            if data
              $('<div></div>').easyDialog({
                content: '提交案例解决方案成功！'
                closeCallback: ->
                  window.location.reload()
              })
            else
              $('<div></div>').easyDialog({
                content: '提交案例解决方案失败！'
              })
            
          )
      }, 'confirm')
      return false
    )

    $('.solution-review').bind('click' , ->
        _this = this
        $('#case-review-dialog').easyDialog({
          confirmButtonClass: 'btn-primary'
          confirmCallback: ->
            $.get(_this.href + '?review_result=' + $('#case-review-dialog input:checked').val() + "&knowledge_base_id=" + $('#knowledge_base_id').val(), (data)->
              if data
                $('<div></div>').easyDialog({
                  content: '审批案例解决方案成功！'
                  closeCallback: ->
                    window.location.reload()
                })

              else
                $('<div></div>').easyDialog({
                  content: '审批案例解决方案失败！'
                })
            )
        }, 'confirm')
        return false
      )

    $('.your_option input[type=radio]').bind('click', ->
      if $(this).val() is 'review'
        $('#knowledge-base-area').hide()
      else if $(this).val() is 'recommend'
        $('#knowledge-base-area').show()
      else
    )
  )
