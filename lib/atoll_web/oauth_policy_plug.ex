defmodule AtollWeb.OAuthPolicyPlug do
  @moduledoc """
  Explicit OAuth policy for local XRPC routes, after proxy selection and rate limits.

  Public reads validate supplied OAuth credentials without granting private access;
  their controllers still use their ordinary public-data checks. Integrated resource
  routes retain their own proof admission and transactional grant checks. Other
  authentication mechanisms cannot be replaced with an OAuth access token.
  """
  @behaviour Plug
  alias AtollWeb.OAuthResource

  @public ~w(
    com.atproto.server.describeServer
    com.atproto.identity.resolveDid
    com.atproto.identity.resolveIdentity
    com.atproto.identity.resolveHandle
    com.atproto.repo.describeRepo
    com.atproto.repo.getRecord
    com.atproto.repo.listRecords
    com.atproto.sync.getRecord
    com.atproto.sync.getBlocks
    com.atproto.sync.getLatestCommit
    com.atproto.sync.getRepoStatus
    com.atproto.sync.listRepos
    com.atproto.sync.listReposByCollection
    com.atproto.sync.subscribeRepos
  )

  @resource ~w(
    app.bsky.actor.getPreferences
    app.bsky.actor.putPreferences
    com.atproto.server.getSession
    com.atproto.server.checkAccountStatus
    com.atproto.server.getServiceAuth
    com.atproto.server.requestEmailConfirmation
    com.atproto.server.confirmEmail
    com.atproto.server.requestEmailUpdate
    com.atproto.server.updateEmail
    com.atproto.identity.getRecommendedDidCredentials
    com.atproto.identity.refreshIdentity
    com.atproto.identity.updateHandle
    com.atproto.identity.requestPlcOperationSignature
    com.atproto.identity.signPlcOperation
    com.atproto.identity.submitPlcOperation
    com.atproto.repo.createRecord
    com.atproto.repo.putRecord
    com.atproto.repo.deleteRecord
    com.atproto.repo.applyWrites
    com.atproto.repo.uploadBlob
    com.atproto.repo.importRepo
    com.atproto.repo.listMissingBlobs
    com.atproto.sync.getRepo
    com.atproto.sync.getBlob
    com.atproto.sync.listBlobs
  )

  @non_oauth ~w(
    com.atproto.server.createInviteCode
    com.atproto.server.createInviteCodes
    com.atproto.server.getAccountInviteCodes
    com.atproto.server.createAppPassword
    com.atproto.server.listAppPasswords
    com.atproto.server.revokeAppPassword
    com.atproto.server.requestAccountDelete
    com.atproto.server.deleteAccount
    com.atproto.server.activateAccount
    com.atproto.server.deactivateAccount
    com.atproto.server.createSession
    com.atproto.server.refreshSession
    com.atproto.server.deleteSession
    com.atproto.server.createAccount
    com.atproto.server.reserveSigningKey
    com.atproto.server.requestPasswordReset
    com.atproto.server.resetPassword
  )

  def init(opts), do: opts

  @doc "Local authentication policy; unknown routes must be classified before accepting OAuth."
  def policy(nsid) when nsid in @public, do: :public
  def policy(nsid) when nsid in @resource, do: :resource
  def policy(nsid) when nsid in @non_oauth, do: :non_oauth
  def policy("com.atproto.admin." <> _), do: :non_oauth
  def policy(_), do: :unclassified

  def call(conn, _) do
    case Enum.map(conn.path_info, &URI.decode/1) do
      ["xrpc", nsid] when conn.method in ["GET", "POST"] ->
        if OAuthResource.attempt?(conn), do: authorize(conn, policy(nsid)), else: conn

      _ ->
        conn
    end
  end

  defp authorize(%{method: "GET"} = conn, :public) do
    case OAuthResource.read_result(conn, fn _ -> :public end) do
      {:ok, :public} -> conn
      {:error, conn} -> conn
    end
  end

  defp authorize(conn, :resource), do: conn
  defp authorize(conn, _), do: OAuthResource.deny(conn)
end
