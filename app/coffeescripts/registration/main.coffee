define [
  'compiled/fn/preventDefault'
  'compiled/registration/signupDialog'
  'jst/registration/login'
], (preventDefault, signupDialog, loginForm) ->
  #$loginForm = null

  $('.signup_link').each (i)->
    signupDialog($(this).data('template'), $(this).prop('title'), i)

  ###$('#registration_video a').click preventDefault ->
    $('<div style="padding:0;"><iframe style="float:left;" src="http://player.vimeo.com/video/35336470?portrait=0&amp;color=7fc8ff&amp;autoplay=1" width="800" height="450" frameborder="0" webkitAllowFullScreen mozallowfullscreen allowFullScreen></iframe></div>')
      .dialog
        width: 800,
        title: "Canvas Introduction Video",
        modal: true,
        resizable: false,
        close: -> $(this).remove()

  $('body').click (e) ->
    unless $(e.target).closest('#registration_login, #login_form').length
      $loginForm?.hide()

  $('#registration_login').on 'click focus', preventDefault ->
    if $loginForm
      $loginForm.toggle()
    else
      $loginForm = $(loginForm(login_handle_name: ENV.USER.LOGIN_HANDLE_NAME))
      $loginForm.appendTo($(this).closest('.registration-content'))
    if $loginForm.is(':visible')
      $loginForm.find('input:visible').eq(0).focus()###
