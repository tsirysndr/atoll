defmodule AtollWeb.Router do
  use AtollWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AtollWeb do
    get "/", HomeController, :show
    get "/.well-known/did.json", ServerController, :identity
    get "/.well-known/atproto-did", IdentityController, :hosted_handle
  end

  scope "/api", AtollWeb do
    pipe_through :api
  end

  scope "/", AtollWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  scope "/xrpc", AtollWeb do
    pipe_through :api

    get "/com.atproto.server.describeServer", ServerController, :describe
    post "/com.atproto.server.createInviteCode", AdminInviteController, :create
    post "/com.atproto.server.createInviteCodes", AdminInviteController, :create_many
    post "/com.atproto.admin.disableInviteCodes", AdminInviteController, :disable
    post "/com.atproto.admin.disableAccountInvites", AdminInviteController, :disable_account
    post "/com.atproto.admin.enableAccountInvites", AdminInviteController, :enable_account
    post "/com.atproto.admin.deleteAccount", AdminAccountController, :delete
    post "/com.atproto.admin.updateAccountPassword", AdminAccountController, :update_password
    post "/com.atproto.admin.updateAccountEmail", AdminAccountController, :update_email
    get "/com.atproto.admin.getAccountInfo", AdminAccountController, :show
    get "/com.atproto.admin.getAccountInfos", AdminAccountController, :index
    get "/com.atproto.admin.getSubjectStatus", AdminSubjectController, :show
    post "/com.atproto.admin.updateSubjectStatus", AdminSubjectController, :update
    get "/com.atproto.admin.getInviteCodes", AdminInviteController, :index
    get "/com.atproto.server.getAccountInviteCodes", SessionController, :invite_codes

    post "/com.atproto.server.requestEmailConfirmation",
         SessionController,
         :request_email_confirmation

    post "/com.atproto.server.confirmEmail", SessionController, :confirm_email
    post "/com.atproto.server.requestEmailUpdate", SessionController, :request_email_update
    post "/com.atproto.server.updateEmail", SessionController, :update_email
    post "/com.atproto.server.requestPasswordReset", SessionController, :request_password_reset
    post "/com.atproto.server.resetPassword", SessionController, :reset_password
    post "/com.atproto.server.createAppPassword", SessionController, :create_app_password
    get "/com.atproto.server.listAppPasswords", SessionController, :list_app_passwords
    post "/com.atproto.server.revokeAppPassword", SessionController, :revoke_app_password
    post "/com.atproto.server.requestAccountDelete", SessionController, :request_account_delete
    post "/com.atproto.server.deleteAccount", SessionController, :delete_account
    post "/com.atproto.server.createSession", SessionController, :create
    post "/com.atproto.server.createAccount", SessionController, :create_account
    get "/com.atproto.server.getSession", SessionController, :show
    get "/com.atproto.server.checkAccountStatus", SessionController, :status
    get "/com.atproto.server.getServiceAuth", SessionController, :service_auth
    post "/com.atproto.server.refreshSession", SessionController, :refresh
    post "/com.atproto.server.deleteSession", SessionController, :delete
    post "/com.atproto.server.activateAccount", SessionController, :activate
    post "/com.atproto.server.deactivateAccount", SessionController, :deactivate
    get "/com.atproto.identity.resolveHandle", IdentityController, :resolve_handle
    get "/com.atproto.identity.getRecommendedDidCredentials", IdentityController, :recommended
    get "/com.atproto.repo.getRecord", RepoController, :get_record
    post "/com.atproto.repo.uploadBlob", BlobController, :upload
    get "/com.atproto.repo.listMissingBlobs", BlobController, :list_missing
    post "/com.atproto.repo.createRecord", RecordWriteController, :create
    post "/com.atproto.repo.putRecord", RecordWriteController, :put
    post "/com.atproto.repo.deleteRecord", RecordWriteController, :delete
    post "/com.atproto.repo.applyWrites", RecordWriteController, :batch
    post "/com.atproto.repo.importRepo", RepoImportController, :create
    get "/com.atproto.repo.describeRepo", RepoController, :describe
    get "/com.atproto.repo.listRecords", RepoController, :list_records
    get "/com.atproto.sync.getLatestCommit", SyncController, :latest_commit
    get "/com.atproto.sync.getRepoStatus", SyncController, :repo_status
    get "/com.atproto.sync.listRepos", SyncController, :list_repos
    get "/com.atproto.sync.listBlobs", BlobController, :list_blobs
  end

  scope "/xrpc", AtollWeb do
    get "/com.atproto.sync.getRepo", RepoController, :get_repo
    get "/com.atproto.sync.getRecord", SyncController, :get_record
    get "/com.atproto.sync.getBlocks", SyncController, :get_blocks
    get "/com.atproto.sync.getBlob", BlobController, :get_blob
  end
end
