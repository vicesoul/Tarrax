define [
  'jquery'
  'underscore'
  'compiled/userSettings'
  'jst/calendar/contextList'
  'jst/calendar/undatedEvents'
  'compiled/calendar/commonEventFactory'
  'compiled/calendar/EditEventDetailsDialog'
  'compiled/calendar/EventDataSource'
  'compiled/jquery.kylemenu'
  'jquery.instructure_misc_helpers'
  'vendor/jquery.ba-tinypubsub'
], ($, {map}, userSettings, contextListTemplate, undatedEventsTemplate, commonEventFactory, EditEventDetailsDialog, EventDataSource) ->

  class VisibleContextManager
    constructor: (contexts, selectedContexts, @$holder) ->
      fragmentData = try
               $.parseJSON($.decodeFromHex(location.hash.substring(1))) || {}
             catch e
               {}

      @contexts   = fragmentData.show.split(',') if fragmentData.show
      @contexts or= selectedContexts
      @contexts or= userSettings.get('checked_calendar_codes')
      @contexts or= (c.asset_string for c in contexts[0...10])

      @notify()

      $.subscribe 'Calendar/saveVisibleContextListAndClear', @saveAndClear
      $.subscribe 'Calendar/restoreVisibleContextList', @restoreList

    saveAndClear: () =>
      if !@savedContexts
        @savedContexts = @contexts
        @contexts = []
        @notify()

    restoreList: () =>
      if @savedContexts
        @contexts = @savedContexts
        @savedContexts = null
        @notify()

    toggle: (context) ->
      index = $.inArray context, @contexts
      if index >= 0
        @contexts.splice index, 1
      else
        @contexts.push context
        @contexts.shift if @contexts.length > 10
      @notify()

    notify: ->
      $.publish 'Calendar/visibleContextListChanged', [@contexts]

      @$holder.find('.context_list_context').each (i, li) =>
        $li = $(li)
        visible = $li.data('context') in @contexts
        $li.toggleClass('checked', visible).toggleClass('not-checked', !visible)

  return sidebar = (contexts, selectedContexts, dataSource) ->
    for c in contexts
      c.can_create_stuff = c.can_create_calendar_events || c.can_create_assignments

    $holder = $('#context-list-holder')

    $holder.html contextListTemplate(contexts: contexts)

    visibleContexts = new VisibleContextManager(contexts, selectedContexts, $holder)

    $holder.find('.settings').kyleMenu
      buttonOpts:
        icons:
          primary:'ui-icon-cog-with-droparrow'
          secondary: null
      popupOpts:
        position:
          offset: '-25px 10px'
          within: '#right-side'

    $holder.delegate '.context_list_context', 'click', (event) ->
      # dont toggle if thy were clicking the .settings button
      unless $(event.target).closest('.settings, .actions').length
        visibleContexts.toggle $(this).data('context')
        userSettings.set('checked_calendar_codes',
          map($(this).parent().children('.checked'), (c) -> $(c).data('context')))

    $holder.delegate '.context_list_context'
      'mouseenter mouseleave': (event) ->
        hovering = !(event.type == 'mouseleave' && !$(this).find('.ui-menu:visible').length)
        $(this).toggleClass('hovering', hovering)
      'popupopen popupclose': (event) ->
        hovering = event.type == 'popupopen'
        $(this).toggleClass('hovering', hovering)
          .find('.settings').toggleClass('ui-state-active', hovering)

    $holder.delegate '.actions a', 'click', ->
      context = $(this).parents('li[data-context]').data('context')
      action = $(this).data('action')
      if action == 'add_event' || action == 'add_assignment'
        event = commonEventFactory(null, contexts)
        new EditEventDetailsDialog(event).show()
        # TODO, codesmell: we should get rid of these next 2 lines and let EditEventDetailsDialog
        # take care of that behaviour
        $('select[class="context_id"]').val(context).triggerHandler('change')
        $('a[href="#edit_assignment_form"]').click() if action == 'add_assignment'
