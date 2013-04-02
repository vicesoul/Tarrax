require [
  'compiled/views/course_settings/NavigationView'
  'compiled/views/course_settings/UserCollectionView'
  'compiled/collections/UserCollection'
  'compiled/views/course_settings/tabs/tabUsers'
  'vendor/jquery.cookie'
  'course_settings'
  'external_tools'
  'grading_standards'
  'jqueryui/dialog'
  'vendor/jquery.tree'
], (NavigationView, UserCollectionView, UserCollection) ->

  nav_view = new NavigationView
    el: $('#tab-navigation')

  loadUsersTab = ->
    window.app = usersTab: {}
    for baseRole in ENV.ALL_ROLES
      eType = baseRole.label.toLowerCase()
      window.app.usersTab["#{eType}sView"] = new UserCollectionView
        el: $("##{eType}_enrollments")
        url: ENV.USERS_URL
        count: baseRole.count
        requestParams:
          enrollment_role: baseRole.base_role_name

      for customRole in baseRole.custom_roles
        continue if customRole.workflow_state == 'inactive' && customRole.count == 0
        window.app.usersTab["#{customRole.asset_string}sView"] = new UserCollectionView
          el: $("##{customRole.asset_string}")
          url: ENV.USERS_URL
          count: customRole.count
          requestParams:
            enrollment_role: customRole.name

  $ ->
    nav_view.render()

    if $("#tab-users").is(":visible")
      loadUsersTab()

    $("#course_details_tabs").bind 'tabsshow', (e,ui) ->
      if ui.tab.hash == '#tab-users' and not window.app?.usersTab
        loadUsersTab()

    $("#accounts_pickup").dialog(
      autoOpen: false
      width: 1024
      height: 768
    )
    
    parseTree = ($obj, arr) ->
      for content in arr
        $li = $("<li class='open'>#{content.label}</li>")
        if content.children.length > 0
          $li.append( parseTree($("<ul></ul>"), content.children) )
        $obj.append $li
      return $obj

    $("#pick_up_from_accounts").bind 'click', (e) -> 
      $("#accounts_pickup").dialog "open"

    $.getJSON $("#accounts_pickup_url").val(), (data) ->
      $html = parseTree $("<ul></ul>"), data
      $("#accounts_pickup #tree").html $html
      $("#accounts_pickup #tree").tree(
        ui:{ theme_name: "checkbox" }
        plugins:{ checkbox: { } }
        callback:{
          onchange: (node, tree) ->
            nodes = tree.container.find("a.checked")
            ids = for node in nodes
              $(node).attr("id").split("_")[1]
            $body = $("#accounts_pickup #users_container tbody")
            $body.html """
                       <tr>
                         <td colspan="3"><img src="/images/ajax-loader-medium-444.gif"/></td>
                       </tr>
                       """
            $.getJSON "/accounts/select/users/ids?ids=#{ids.join('-')}", (users) ->
              $body.html "" # reset html
              for user in users
                tr =  """
                      <tr class="user_info_checked">
                        <td><input type="checkbox" class="checkOrNot" checked></td>
                        <td>#{user.name}</td>
                        <td class="email">#{user.email}</td>
                      </tr>
                      """
                $body.append(tr)
              $("#accounts_pickup .button-container").show()

              $body.find(".checkOrNot").click ()->
                if $(this).is(":checked")
                  $(this).parents('tr').addClass "user_info_checked"
                else
                  $(this).parents('tr').removeClass "user_info_checked"

              $("#checkboxAll").prop 'checked', true
        }
      )


      $("#checkboxAll").click ()->
        if $(this).is(":checked")
          $(".checkOrNot").prop 'checked', true
          $(".checkOrNot").parents('tr').addClass "user_info_checked"
        else
          $(".checkOrNot").prop 'checked', false
          $(".checkOrNot").parents('tr').removeClass "user_info_checked"

      $("#accounts_pickup .inseart_users").click ->
        emails = ""
        for email in $("#users_container .user_info_checked .email")
          emails += "#{$(email).text()}\n"
        $area = $("#user_list_textarea_container .user_list")
        $area.val( $area.val() + emails )
        $("#accounts_pickup").dialog "close"
