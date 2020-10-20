require_relative '../lib/auth_helpers'

class ArchivesSpaceService < Sinatra::Base

  include AuthHelpers


  Endpoint.post('/users')
    .description("Create a user")
    .params(["password", String, "The user's password"],
            ["groups", [String], "Array of groups URIs to assign the user to", :optional => true],
            ["user", JSONModel(:user), "The record to create", :body => true])
    .permissions([])
    .returns([200, :created],
             [400, :error]) \
  do
    check_admin_access
    params[:user].username = Username.value(params[:user].username)

    user = User.create_from_json(params[:user], :source => "local")
    DBAuth.set_password(params[:user].username, params[:password])

    groups = Array(params[:groups]).map {|uri|
      group_ref = JSONModel.parse_reference(uri)
      repo_id = JSONModel.parse_reference(group_ref[:repository])[:id]

      RequestContext.open(:repo_id => repo_id) do
        if current_user.can?(:manage_repository)
          Group.get_or_die(group_ref[:id])
        else
          raise AccessDeniedException.new
        end
      end
    }

    user.add_to_groups(groups)

    created_response(user, params[:user])
  end


  Endpoint.get('/users')
    .description("Get a list of users")
    .example('python') do
      <<~PYTHON
        from asnake.aspace import ASpace
        aspace = ASpace()
        users = [(u.uri, u.username) for u in aspace.users()]
        # return tuples of user data.
      PYTHON
    end
    .params()
    .paginated(true)
    .permissions([])
    .returns([200, "[(:resource)]"]) \
  do
    handle_listing(User, params, {:exclude => {:id => User.unlisted_user_ids}})
  end


  Endpoint.get('/users/current-user')
    .description("Get the currently logged in user")
    .example('python') do
      <<~PYTHON
        from asnake.aspace import ASpace
        aspace = ASpace()
        current_user = aspace.users.current_user
      PYTHON
    end
    .params()
    .permissions([])
    .returns([200, "(:user)"],
             [404, "Not logged in"]) \
  do
    if current_user.anonymous?
      raise NotFoundException.new
    else
      json = User.to_jsonmodel(current_user)
      json.permissions = current_user.permissions
      json_response(json)
    end
  end


  Endpoint.get('/users/complete')
    .description("Get a list of system users")
    .example('python') do
      <<~PYTHON
        from asnake.client import ASnakeClient
        client = ASnakeClient()
        users = client.get("/users/complete", params={"query": "test"}).json()
        # return list of usernames that contain query prefix.
      PYTHON
    end
    .params(["query", String, "A prefix to search for"])
    .permissions([])
    .returns([200, "A list of usernames"]) \
  do
    usernames = AuthenticationManager.matching_usernames(params[:query])

    json_response(usernames)
  end




  Endpoint.get('/users/:id')
    .description("Get a user's details (including their current permissions)")
    .example('python') do
      <<~PYTHON
        from asnake.aspace import ASpace
        aspace = ASpace()
        a_user = aspace.users(1)
      PYTHON
    end
    .params(["id", Integer, "The username id to fetch"])
    .permissions([:manage_users])
    .returns([200, "(:user)"]) \
  do
    user = User[params[:id]]

    if user
      json = User.to_jsonmodel(user)
      json.permissions = user.permissions

      json_response(json)
    else
      raise NotFoundException.new("User wasn't found")
    end
  end


  Endpoint.post('/users/:id/groups')
    .description("Update a user's groups")
    .params(["id", :id],
            ["groups", [String], "Array of groups URIs to assign the user to", :optional => true],
            ["remove_groups", BooleanParam, "Remove all groups from the user for the current repo_id if true"],
            ["repo_id", Integer, "The Repository groups to clear"])
    .permissions([])            # permissions are enforced in the body for this one
    .returns([200, :updated],
             [400, :error]) \
  do
    user = User.get_or_die(params[:id])

    # Low security: if a repo_id is provided, we're just running in "set
    # groups for this repo" mode.
    groups = Array(params[:groups]).map {|uri|
      group_ref = JSONModel.parse_reference(uri)
      repo_id = JSONModel.parse_reference(group_ref[:repository])[:id]

      next if repo_id != params[:repo_id]

      RequestContext.open(:repo_id => repo_id) do
        if current_user.can?(:manage_repository)
          Group.get_or_die(group_ref[:id])
        else
          raise AccessDeniedException.new
        end
      end
    }

    user.add_to_groups(groups, params[:repo_id])

    json_response(:status => "OK")
  end


  Endpoint.post('/users/:id')
    .description("Update a user's account")
    .example('python') do
      <<~PYTHON
        from asnake.aspace import ASpace
        aspace = ASpace()
        a_user = aspace.users(1)
        updated_user_json = a_user.json()
        # update some values
        updated_user_json["name"] = "Testy McTestFace"
        updated_user_json["is_admin"] = False
        # post update
        response = aspace.client.post(a_user.uri, json=updated_user_json)
      PYTHON
    end
    .params(["id", :id],
            ["password", String, "The user's password", :optional => true],
            ["user", JSONModel(:user), "The updated record", :body => true])
    .permissions([])            # permissions are enforced in the body for this one
    .returns([200, :updated],
             [400, :error]) \
  do
    check_admin_access
    user = User.get_or_die(params[:id])

    # High security: update the user themselves.
    raise AccessDeniedException.new if !current_user.can?(:manage_users)

    params[:user].username = Username.value(params[:user].username)

    user.update_from_json(params[:user])

    if params[:password]
      DBAuth.set_password(params[:user].username, params[:password])
    end

    updated_response(user, params[:user])
  end


  Endpoint.post('/users/:username/login')
    .description("Log in")
    .params(["username", Username, "Your username"],
            ["password", String, "Your password"],
            ["expiring", BooleanParam,
             "If true, the session will expire after " +
             "#{AppConfig[:session_expire_after_seconds]}" +
             " seconds of inactivity.  If false, it will " +
             " expire after " +
             "#{AppConfig[:session_nonexpirable_force_expire_after_seconds]}" +
             " seconds of inactivity." +
             "\n\n" +
             "NOTE: Previously this parameter would cause the created session" +
             " to last forever, but this generally isn't what you want.  The parameter" +
             " name is unfortunate, but we're keeping it for backward-compatibility.",
             :default => true])
    .permissions([])
    .returns([200, "Login accepted"],
             [403, "Login failed"]) \
  do
    username = params[:username]

    user = AuthenticationManager.authenticate(username, params[:password])

    if user
      session = create_session_for(username, params[:expiring])
      json_user = User.to_jsonmodel(user)
      json_user.permissions = user.permissions
      json_response({:session => session.id, :user => json_user})
    else
      json_response({:error => "Login failed"}, 403)
    end
  end


  Endpoint.post('/users/:username/become-user')
    .description("Become a different user")
    .params(["username", Username, "The username to become"])
    .permissions([:become_user])
    .returns([200, "Accepted"],
             [404, "User not found"]) \
  do
    username = params[:username]
    user = User.find(:username => username)

    raise NotFoundException.new if !user

    session[:user] = username
    session.save

    json_user = User.to_jsonmodel(user)
    json_user.permissions = user.permissions

    json_response({:session => session.id, :user => json_user})
  end


  Endpoint.get('/repositories/:repo_id/users/:id')
  .description("Get a user's details including their groups for the current repository")
  .params(["id", Integer, "The user id to fetch"],
          ["repo_id", :repo_id])
  .permissions([:manage_repository])
  .returns([200, "(:user)"]) \
  do
    user = User[params[:id]]

    if user
      json = User.to_jsonmodel(user)
      json.groups = user.group_dataset.where(:repo_id => params[:repo_id]).map do |group|
        JSONModel(:group).uri_for(group.id, :repo_id => params[:repo_id])
      end

      json_response(json)
    else
      raise NotFoundException.new("User wasn't found")
    end
  end



  Endpoint.delete('/users/:id')
    .description("Delete a user")
    .example('python') do
      <<~PYTHON
        from asnake.aspace import ASpace
        aspace = ASpace()
        delete = aspace.client.delete("users/1")
      PYTHON
    end
    .params(["id", Integer, "The user to delete"])
    .permissions([:manage_users])
    .returns([200, :deleted]) \
  do
    handle_delete(User, params[:id])
  end


  Endpoint.post('/logout')
    .description("Log out the current session")
    .permissions([])
    .returns([200, "Session logged out"]) \
  do
    if session
      Session.expire(session.id)
      json_response('status' => 'session_logged_out')
    else
      json_response('status' => 'no_active_session')
    end
  end


  private

  def check_admin_access
    if params[:user].is_admin && !current_user.can?(:administer_system)
      raise AccessDeniedException.new("Only admins can create admin users")
    end

    # Saving people from themselves :)
    about_to_remove_own_permission = (params[:user].username == current_user.username)

    RequestContext.put(:apply_admin_access,
                       current_user.can?(:administer_system) && !about_to_remove_own_permission)
  end

end
