define ['Backbone'], ({View}, _) ->

  ##
  # Makes an input field that emits `input` and `select` events, and
  # automatically selects itself if the user presses the enter key (don't have
  # to backspace out the text, or if you do, it deletes all of it).
  #
  # Events:
  #
  #   input: Emits after a short delay so it doesn't fire off the event with
  #   every keyup from the user, sends the value of the input in the event
  #   parameters.
  #
  #   enter: Emits when the user hits enter in the field
  class InputFilterView extends View

    tagName: 'input'

    events: {'keyup', 'change'}

    defaults:
      onInputDelay: 200

    onInput: =>
      @trigger 'input', @el.value

    onEnter: ->
      @el.select()
      @trigger 'enter', @el.value

    keyup: (event) ->
      clearTimeout @onInputTimer
      @onInputTimer = setTimeout @onInput, @options.onInputDelay
      @onEnter() if event.which? and event.which is 13
      null

    change: @::keyup
