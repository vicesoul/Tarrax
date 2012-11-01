define [
  'jquery'
  'compiled/fn/preventDefault'
  'jqueryui/dialog'
], ($, preventDefault) ->

  $.fn.fixDialogButtons = ->
    this.each ->
      $dialog = $(this)
      $buttons = $dialog.find(".button-container:last .button, button[type=submit]")
      if $buttons.length
        $dialog.find(".button-container:last, button[type=submit]").hide()
        buttons = $.map $buttons.toArray(), (button) ->
          $button = $(button)

          # if you add the class 'dialog_closer' to any of the buttons,
          # clicking it will cause the dialog to close
          if $button.is('.dialog_closer')
            $button.click preventDefault -> $dialog.dialog('close')

          # make it so if you hit enter in the dialog, you submit the form
          if $button.prop('type') is 'submit' && $button[0].form
            $dialog.keypress (e) ->
              $($button[0].form).submit() if e.keyCode is $.ui.keyCode.ENTER

          return {
            text: $button.text()
            "data-text-while-loading": $button.data("textWhileLoading")
            click: -> $button.click()
            class: $button.attr('class')
          }
        $dialog.dialog "option", "buttons", buttons