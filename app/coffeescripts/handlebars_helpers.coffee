define [
  'ENV'
  'vendor/handlebars.vm'
  'i18nObj'
  'jquery'
  'underscore'
  'str/htmlEscape'
  'compiled/util/semanticDateRange'
  'compiled/util/dateSelect'
  'compiled/str/convertApiUserContent'
  'jquery.instructure_date_and_time'
  'jquery.instructure_misc_helpers'
  'jquery.instructure_misc_plugins'
], (ENV, Handlebars, I18n, $, _, htmlEscape, semanticDateRange, dateSelect, convertApiUserContent) ->

  Handlebars.registerHelper name, fn for name, fn of {
    t : (key, defaultValue, options) ->
      wrappers = {}
      options = options?.hash ? {}
      for key, value of options when key.match(/^w\d+$/)
        wrappers[new Array(parseInt(key.replace('w', '')) + 2).join('*')] = value
        delete options[key]
      options.wrapper = wrappers if wrappers['*']
      options = $.extend(options, this) unless this instanceof String or typeof this is 'string'
      I18n.scoped(options.scope).t(key, defaultValue, options)

    hiddenIf : (condition) -> " display:none; " if condition

    hiddenUnless : (condition) -> " display:none; " unless condition

    semanticDateRange : ->
      new Handlebars.SafeString semanticDateRange arguments...

    friendlyDatetime : (datetime, {hash: {pubdate}}) ->
      return unless datetime?

      # if datetime is already a date convert it back into an ISO string to parseFromISO,
      # TODO: be smarter about this
      datetime = $.dateToISO8601UTC(datetime) if _.isDate datetime

      parsed = $.parseFromISO(datetime)
      new Handlebars.SafeString "<time title='#{parsed.datetime_formatted}' datetime='#{parsed.datetime.toISOString()}' #{'pubdate' if pubdate}>#{$.friendlyDatetime(parsed.datetime)}</time>"

    # expects: a Date object
    formattedDate : (datetime, format, {hash: {pubdate}}) ->
      return unless datetime?
      new Handlebars.SafeString "<time title='#{datetime}' datetime='#{datetime.toISOString()}' #{'pubdate' if pubdate}>#{datetime.toString(format)}</time>"

    datetimeFormatted : (isoString) ->
      return '' unless isoString
      isoString = $.parseFromISO(isoString) unless isoString.datetime
      isoString.datetime_formatted

    # helper for using date.js's custom toString method on Date objects
    dateToString : (date = '', format) ->
      date.toString(format)

    mimeClass: (contentType) -> $.mimeClass(contentType)

    # use this method to process any user content fields returned in api responses
    # this is important to handle object/embed tags safely, and to properly display audio/video tags
    convertApiUserContent: (html, {hash}) ->
      new Handlebars.SafeString convertApiUserContent(html, hash)

    newlinesToBreak : (string) ->
      new Handlebars.SafeString htmlEscape(string).replace(/\n/g, "<br />")

    # runs block if all arguments are === to each other
    # usage:
    # {{#ifEqual argument1 argument2 'a string argument' argument4}}
    #   everything was equal
    # {{else}}
    #   everything was NOT equal
    # {{/ifEqual}}
    ifEqual: ->
      [previousArg, args..., {fn, inverse}] = arguments
      for arg in args
        return inverse(this) if arg != previousArg
        previousArg = arg
      fn(this)

    # runs block if *ALL* arguments are truthy
    # usage:
    # {{#ifAll arg1 arg2 arg3 arg}}
    #   everything was truthy
    # {{else}}
    #   something was falsey
    # {{/ifAll}}
    ifAll: ->
      [args..., {fn, inverse}] = arguments
      for arg in args
        return inverse(this) unless arg
      fn(this)

    # runs block if *ANY* arguments are truthy
    # usage:
    # {{#ifAny arg1 arg2 arg3 arg}}
    #   something was truthy
    # {{else}}
    #   all were falsy
    # {{/ifAny}}
    ifAny: ->
      [args..., {fn, inverse}] = arguments
      for arg in args
        return fn(this) if arg
      inverse(this)

    eachWithIndex: (context, options) ->
      fn = options.fn
      inverse = options.inverse
      ret = ''

      if context and context.length > 0
        for index, ctx of context
          ctx._index = index
          ret += fn ctx
      else
        ret = inverse this

      ret

    # loop through an object's properties, exposing "property" and
    # "value."
    #
    # ex.
    #
    # obj =
    #   group_one: [
    #     { label: 'one', val: 1 }
    #     { label: 'two', val: 2 }
    #   ],
    #   group_two: [
    #     { label: 'three', val: 3 }
    #     { label: 'four', val: 4 }
    #   ]
    #
    # {{#eachProp this}}
    #   <optgroup label="{{property}}">
    #     {{#each this.value}}
    #       <option value="{{val}}">{{label}}</option>
    #     {{/each}}
    #   </optgroup>
    # {{/each}}
    #
    # outputs:
    # <optgroup label="group_one">
    #   <option value="1">one</option>
    #   <option value="2">two</option>
    # </optgroup>
    # <optgroup label="group_two">
    #   <option value="3">three</option>
    #   <option value="4">four</option>
    # </optgroup>
    #
    eachProp: (context, options) ->
      (options.fn(property: prop, value: context[prop]) for prop of context).join ''

    # evaluates the block for each item in context and passes the result to $.toSentence
    toSentence: (context, options) ->
      results = _.map(context, (c) -> options.fn(c))
      $.toSentence(results)

    dateSelect: (name, options) ->
      new Handlebars.SafeString dateSelect(name, options.hash).html()

    ##
    # usage:
    #   if 'this' is {human: true}
    #   and you do: {{checkbox "human"}}
    #   you'll get: <input name="human" type="hidden" value="0" />
    #               <input type="checkbox"
    #                      value="1"
    #                      id="human"
    #                      checked="true"
    #                      name="human" >
    # you can pass custom attributes and use nested properties:
    #   if 'this' is {likes: {tacos: true}}
    #   and you do: {{checkbox "likes.tacos" class="foo bar"}}
    #   you'll get: <input name="likes[tacos]" type="hidden" value="0" />
    #               <input type="checkbox"
    #                      value="1"
    #                      id="likes_tacos"
    #                      checked="true"
    #                      name="likes[tacos]"
    #                      class="foo bar" >
    checkbox : (propertyName, {hash}) ->
      splitPropertyName = propertyName.split(/\./)
      snakeCase = splitPropertyName.join('_')
      bracketNotation = splitPropertyName[0] + _.chain(splitPropertyName)
                                                .rest()
                                                .map((prop) -> "[#{prop}]")
                                                .value()
                                                .join('')
      inputProps = _.extend
        type: 'checkbox'
        value: 1
        id: snakeCase
        name: bracketNotation
      , hash

      unless inputProps.checked
        value = _.reduce splitPropertyName, ((memo, key) -> memo[key]), this
        inputProps.checked = true if value

      attributes = _.map inputProps, (val, key) -> "#{htmlEscape key}=\"#{htmlEscape val}\""
      new Handlebars.SafeString """
        <input name="#{htmlEscape inputProps.name}" type="hidden" value="0" />
        <input #{attributes.join ' '} />
      """

    toPercentage: (number) ->
      parseInt(100 * number) + "%"
  }
  return Handlebars
