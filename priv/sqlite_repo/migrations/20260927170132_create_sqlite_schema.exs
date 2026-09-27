defmodule Atoll.Repo.Migrations.CreateSqliteSchema do
  use Ecto.Migration

  # SQLite baseline equivalent to PostgreSQL migrations through
  # 20260927072902. Future schema changes must have migrations for both adapters.
  def up do
    execute """
    CREATE TABLE "account_passkey_challenges" (
      "digest" BLOB NOT NULL,
      "browser_hash" BLOB NOT NULL,
      "challenge" BLOB NOT NULL,
      "kind" TEXT NOT NULL,
      "origin" TEXT NOT NULL,
      "rp_id" TEXT NOT NULL,
      "did" TEXT,
      "source_session_id" TEXT,
      "credential_digest" BLOB,
      "totp_version" TEXT,
      "name" TEXT,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "account_passkey_challenges_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_passkey_challenges_pkey" PRIMARY KEY (digest),
      CONSTRAINT "account_passkey_challenges_source_session_id_fkey" FOREIGN KEY (source_session_id) REFERENCES account_sessions(id) ON DELETE CASCADE,
      CONSTRAINT "passkey_challenge_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (length(CAST(browser_hash AS BLOB)) = 32) AND (length(CAST(challenge AS BLOB)) = 32) AND (expires_at > 0) AND (((kind = 'register') AND (did IS NOT NULL) AND (source_session_id IS NOT NULL) AND (credential_digest IS NOT NULL) AND (length(CAST(credential_digest AS BLOB)) = 32) AND (name IS NOT NULL)) OR ((kind = 'login') AND (did IS NULL) AND (source_session_id IS NULL) AND (credential_digest IS NULL) AND (totp_version IS NULL) AND (name IS NULL)))))
    )
    """

    execute """
    CREATE TABLE "account_passkey_users" (
      "did" TEXT NOT NULL,
      "user_handle" BLOB NOT NULL,
      CONSTRAINT "account_passkey_users_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_passkey_users_pkey" PRIMARY KEY (did),
      CONSTRAINT "passkey_user_shape" CHECK ((length(CAST(user_handle AS BLOB)) = 32))
    )
    """

    execute """
    CREATE TABLE "account_passkeys" (
      "id" TEXT NOT NULL,
      "did" TEXT NOT NULL,
      "credential_id" BLOB NOT NULL,
      "public_key" BLOB NOT NULL,
      "rp_id" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "sign_count" INTEGER NOT NULL,
      "backup_eligible" INTEGER NOT NULL,
      "backup_state" INTEGER NOT NULL,
      "created_at" INTEGER NOT NULL,
      "last_used_at" INTEGER,
      CONSTRAINT "account_passkeys_did_fkey" FOREIGN KEY (did) REFERENCES account_passkey_users(did) ON DELETE CASCADE,
      CONSTRAINT "account_passkeys_pkey" PRIMARY KEY (id),
      CONSTRAINT "passkey_shape" CHECK ((((length(CAST(credential_id AS BLOB)) >= 1) AND (length(CAST(credential_id AS BLOB)) <= 1023)) AND (length(CAST(public_key AS BLOB)) = 65) AND ((length(CAST(name AS BLOB)) >= 1) AND (length(CAST(name AS BLOB)) <= 64)) AND ((sign_count >= 0) AND (sign_count <= '4294967295')) AND ((NOT backup_state) OR backup_eligible) AND (created_at > 0)))
    )
    """

    execute """
    CREATE TABLE "account_preferences" (
      "did" TEXT NOT NULL,
      "preferences" TEXT NOT NULL DEFAULT '[]',
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      CONSTRAINT "account_preferences_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_preferences_pkey" PRIMARY KEY (did),
      CONSTRAINT "preferences_are_an_array" CHECK ((json_type(preferences) = 'array'))
    )
    """

    execute """
    CREATE TABLE "account_profiles" (
      "did" TEXT NOT NULL,
      "handle" TEXT NOT NULL,
      "email" TEXT,
      "email_confirmed_at" TEXT,
      "import_curve" TEXT,
      "import_public_key" BLOB,
      "import_head" BLOB,
      "import_rev" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "email_confirmation_digest" BLOB,
      "email_confirmation_expires_at" INTEGER,
      "email_confirmation_requested_at" INTEGER,
      "email_update_digest" BLOB,
      "email_update_expires_at" INTEGER,
      "email_update_requested_at" INTEGER,
      "password_reset_digest" BLOB,
      "password_reset_expires_at" INTEGER,
      "password_reset_requested_at" INTEGER,
      "email_auth_factor" INTEGER NOT NULL DEFAULT false,
      "auth_factor_digest" BLOB,
      "auth_factor_expires_at" INTEGER,
      "auth_factor_requested_at" INTEGER,
      "deletion_digest" BLOB,
      "deletion_expires_at" INTEGER,
      "deletion_requested_at" INTEGER,
      "invites_disabled" INTEGER NOT NULL DEFAULT false,
      "invite_control_note" TEXT,
      "invites_updated_at" TEXT,
      "plc_signature_digest" BLOB,
      "plc_signature_expires_at" INTEGER,
      "plc_signature_requested_at" INTEGER,
      CONSTRAINT "account_profiles_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_profiles_pkey" PRIMARY KEY (did),
      CONSTRAINT "auth_factor_token_shape" CHECK ((((auth_factor_digest IS NULL) AND (auth_factor_expires_at IS NULL)) OR ((auth_factor_digest IS NOT NULL) AND (length(CAST(auth_factor_digest AS BLOB)) = 32) AND (auth_factor_expires_at IS NOT NULL) AND (auth_factor_requested_at IS NOT NULL)))),
      CONSTRAINT "deletion_token_shape" CHECK ((((deletion_digest IS NULL) AND (deletion_expires_at IS NULL)) OR ((deletion_digest IS NOT NULL) AND (length(CAST(deletion_digest AS BLOB)) = 32) AND (deletion_expires_at IS NOT NULL) AND (deletion_requested_at IS NOT NULL)))),
      CONSTRAINT "email_confirmation_token_shape" CHECK ((((email_confirmation_digest IS NULL) AND (email_confirmation_expires_at IS NULL)) OR ((email_confirmation_digest IS NOT NULL) AND (length(CAST(email_confirmation_digest AS BLOB)) = 32) AND (email_confirmation_expires_at IS NOT NULL) AND (email_confirmation_requested_at IS NOT NULL)))),
      CONSTRAINT "email_factor_confirmed" CHECK (((NOT email_auth_factor) OR ((email IS NOT NULL) AND (email_confirmed_at IS NOT NULL)))),
      CONSTRAINT "email_update_token_shape" CHECK ((((email_update_digest IS NULL) AND (email_update_expires_at IS NULL)) OR ((email_update_digest IS NOT NULL) AND (length(CAST(email_update_digest AS BLOB)) = 32) AND (email_update_expires_at IS NOT NULL) AND (email_update_requested_at IS NOT NULL)))),
      CONSTRAINT "import_signing_key" CHECK ((((import_curve IS NULL) AND (import_public_key IS NULL)) OR ((import_curve IS NOT NULL) AND (import_public_key IS NOT NULL) AND ((import_curve) IN ('k256', 'p256')) AND (length(CAST(import_public_key AS BLOB)) = 33)))),
      CONSTRAINT "normalized_email" CHECK (((email IS NULL) OR (email = lower(email)))),
      CONSTRAINT "normalized_handle" CHECK ((handle = lower(handle))),
      CONSTRAINT "password_reset_token_shape" CHECK ((((password_reset_digest IS NULL) AND (password_reset_expires_at IS NULL)) OR ((password_reset_digest IS NOT NULL) AND (length(CAST(password_reset_digest AS BLOB)) = 32) AND (password_reset_expires_at IS NOT NULL) AND (password_reset_requested_at IS NOT NULL))))
    )
    """

    execute """
    CREATE TABLE "account_sessions" (
      "id" TEXT NOT NULL,
      "did" TEXT NOT NULL,
      "refresh_hash" BLOB NOT NULL,
      "expires_at" INTEGER NOT NULL,
      "app_password_id" TEXT,
      "access_scope" TEXT NOT NULL DEFAULT 'com.atproto.access',
      "passkey_id" TEXT,
      CONSTRAINT "account_sessions_app_password_id_fkey" FOREIGN KEY (app_password_id) REFERENCES app_passwords(id) ON DELETE CASCADE,
      CONSTRAINT "account_sessions_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_sessions_passkey_id_fkey" FOREIGN KEY (passkey_id) REFERENCES account_passkeys(id) ON DELETE CASCADE,
      CONSTRAINT "account_sessions_pkey" PRIMARY KEY (id),
      CONSTRAINT "refresh_hash_length" CHECK ((length(CAST(refresh_hash AS BLOB)) = 32)),
      CONSTRAINT "session_app_scope" CHECK ((((app_password_id IS NULL) AND (access_scope = 'com.atproto.access')) OR ((app_password_id IS NOT NULL) AND (access_scope IN ('com.atproto.appPass', 'com.atproto.appPassPrivileged'))))),
      CONSTRAINT "session_expiration" CHECK ((expires_at > 0)),
      CONSTRAINT "session_passkey_scope" CHECK (((passkey_id IS NULL) OR ((app_password_id IS NULL) AND (access_scope = 'com.atproto.access'))))
    )
    """

    execute """
    CREATE TABLE "account_totp_factors" (
      "did" TEXT NOT NULL,
      "version" TEXT NOT NULL,
      "envelope" BLOB NOT NULL,
      "credential_digest" BLOB NOT NULL,
      "pending_expires_at" INTEGER,
      "confirmed_at" INTEGER,
      "last_used_step" INTEGER NOT NULL DEFAULT '-1',
      "attempts" INTEGER NOT NULL DEFAULT 0,
      "window_started_at" INTEGER NOT NULL DEFAULT 0,
      "recovery_hashes" TEXT NOT NULL DEFAULT '[]',
      CONSTRAINT "account_totp_factors_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "account_totp_factors_pkey" PRIMARY KEY (did),
      CONSTRAINT "totp_factor_shape" CHECK (((length(CAST(envelope AS BLOB)) = 49) AND (length(CAST(credential_digest AS BLOB)) = 32) AND (length(version) = 43) AND (last_used_step >= '-1') AND ((attempts >= 0) AND (attempts <= 5)) AND (window_started_at >= 0) AND (((confirmed_at IS NULL) AND (pending_expires_at IS NOT NULL)) OR ((confirmed_at IS NOT NULL) AND (pending_expires_at IS NULL))))),
      CONSTRAINT "totp_recovery_bound" CHECK (((json_array_length(recovery_hashes) <= 10) AND (instr(recovery_hashes, 'null') = 0)))
    )
    """

    execute """
    CREATE TABLE "app_passwords" (
      "id" TEXT NOT NULL,
      "did" TEXT NOT NULL,
      "name" TEXT NOT NULL,
      "digest" BLOB NOT NULL,
      "privileged" INTEGER NOT NULL DEFAULT false,
      "inserted_at" TEXT NOT NULL,
      CONSTRAINT "app_password_digest_size" CHECK ((length(CAST(digest AS BLOB)) = 32)),
      CONSTRAINT "app_passwords_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "app_passwords_pkey" PRIMARY KEY (id)
    )
    """

    execute """
    CREATE TABLE "blob_cleanup_jobs" (
      "cid" BLOB NOT NULL,
      "backend" TEXT NOT NULL,
      "queued_at" TEXT NOT NULL,
      CONSTRAINT "blob_cleanup_jobs_pkey" PRIMARY KEY (cid, backend),
      CONSTRAINT "cleanup_backend" CHECK ((backend IN ('postgres', 's3'))),
      CONSTRAINT "cleanup_raw_cid" CHECK (((length(CAST(cid AS BLOB)) = 36) AND (substr(cid, 1, 4) = X'01551220')))
    )
    """

    execute """
    CREATE TABLE "blob_references" (
      "did" TEXT NOT NULL,
      "path" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      "mime_type" TEXT NOT NULL,
      "size" INTEGER NOT NULL,
      "rev" TEXT NOT NULL,
      CONSTRAINT "blob_references_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "blob_references_pkey" PRIMARY KEY (did, path, cid),
      CONSTRAINT "reference_size" CHECK ((size >= 0))
    )
    """

    execute """
    CREATE TABLE "blob_takedowns" (
      "did" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      "ref" TEXT,
      CONSTRAINT "blob_takedown_ref_size" CHECK (((ref IS NULL) OR (length(CAST(ref AS BLOB)) <= 2000))),
      CONSTRAINT "blob_takedowns_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "blob_takedowns_pkey" PRIMARY KEY (did, cid)
    )
    """

    execute """
    CREATE TABLE "blocks" (
      "cid" BLOB NOT NULL,
      "data" BLOB NOT NULL,
      "inserted_at" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f000', 'now')),
      CONSTRAINT "blocks_cid_length" CHECK ((length(CAST(cid AS BLOB)) = 36)),
      CONSTRAINT "blocks_pkey" PRIMARY KEY (cid)
    )
    """

    execute """
    CREATE TABLE "event_retention_state" (
      "id" INTEGER NOT NULL,
      "cursor_floor" INTEGER NOT NULL DEFAULT 0,
      CONSTRAINT "event_retention_state_pkey" PRIMARY KEY (id),
      CONSTRAINT "singleton_event_retention" CHECK (((id = 1) AND (cursor_floor >= 0)))
    )
    """

    execute """
    CREATE TABLE "event_revision_dependencies" (
      "seq" INTEGER NOT NULL,
      "head" BLOB NOT NULL,
      "did" TEXT NOT NULL,
      CONSTRAINT "event_revision_dependencies_pkey" PRIMARY KEY (seq, head),
      CONSTRAINT "event_revision_dependencies_seq_fkey" FOREIGN KEY (seq) REFERENCES repository_events(seq) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE "handle_change_reservations" (
      "handle" TEXT NOT NULL,
      "did" TEXT NOT NULL,
      "cid" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      CONSTRAINT "handle_change_reservations_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "handle_change_reservations_pkey" PRIMARY KEY (handle),
      CONSTRAINT "handle_change_update_fk" FOREIGN KEY (did, cid) REFERENCES plc_updates(did, cid) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE "identity_refresh_leases" (
      "did" TEXT NOT NULL,
      "token" BLOB NOT NULL,
      "leased_until" TEXT NOT NULL,
      "next_attempt_at" TEXT NOT NULL,
      CONSTRAINT "identity_refresh_leases_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "identity_refresh_leases_pkey" PRIMARY KEY (did),
      CONSTRAINT "refresh_token_length" CHECK ((length(CAST(token AS BLOB)) = 32))
    )
    """

    execute """
    CREATE TABLE "imported_plc_rotation_keys" (
      "did" TEXT NOT NULL,
      "curve" TEXT NOT NULL,
      "public_key" BLOB NOT NULL,
      "verified_cid" TEXT NOT NULL,
      "envelope" BLOB NOT NULL,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      CONSTRAINT "imported_plc_rotation_keys_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "imported_plc_rotation_keys_pkey" PRIMARY KEY (did),
      CONSTRAINT "valid_imported_rotation_key" CHECK ((((curve) IN ('k256', 'p256')) AND (length(CAST(public_key AS BLOB)) = 33) AND (length(CAST(envelope AS BLOB)) = 61)))
    )
    """

    execute """
    CREATE TABLE "invite_codes" (
      "code" TEXT NOT NULL,
      "use_count" INTEGER NOT NULL,
      "remaining" INTEGER NOT NULL,
      "disabled" INTEGER NOT NULL DEFAULT false,
      "for_account" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "created_by" TEXT NOT NULL DEFAULT 'admin',
      CONSTRAINT "invite_codes_pkey" PRIMARY KEY (code),
      CONSTRAINT "invite_use_bounds" CHECK ((((use_count >= 1) AND (use_count <= 10000)) AND ((remaining >= 0) AND (remaining <= use_count))))
    )
    """

    execute """
    CREATE TABLE "invite_uses" (
      "did" TEXT NOT NULL,
      "code" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      CONSTRAINT "invite_uses_code_fkey" FOREIGN KEY (code) REFERENCES invite_codes(code),
      CONSTRAINT "invite_uses_pkey" PRIMARY KEY (did)
    )
    """

    execute """
    CREATE TABLE "moderation_audit_entries" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      "did" TEXT,
      "subject" TEXT NOT NULL,
      "actor" TEXT NOT NULL,
      "operation" TEXT NOT NULL,
      "requested" TEXT NOT NULL,
      "before_state" TEXT NOT NULL,
      "after_state" TEXT NOT NULL,
      "time" TEXT NOT NULL
    )
    """

    execute """
    CREATE TABLE "oauth_access_tokens" (
      "digest" BLOB NOT NULL,
      "session_id" TEXT NOT NULL,
      "expires_at" INTEGER NOT NULL,
      "scope" TEXT NOT NULL,
      "permission_sets" TEXT NOT NULL DEFAULT '{}',
      CONSTRAINT "oauth_access_token_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0))),
      CONSTRAINT "oauth_access_tokens_permission_sets_shape" CHECK (((json_type(permission_sets) = 'object') AND (length(CAST((permission_sets) AS BLOB)) <= 2097152))),
      CONSTRAINT "oauth_access_tokens_pkey" PRIMARY KEY (digest),
      CONSTRAINT "oauth_access_tokens_session_id_fkey" FOREIGN KEY (session_id) REFERENCES oauth_sessions(id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE "oauth_authorization_codes" (
      "digest" BLOB NOT NULL,
      "did" TEXT NOT NULL,
      "source_session_id" TEXT NOT NULL,
      "issuer" TEXT NOT NULL,
      "client_id" TEXT NOT NULL,
      "redirect_uri" TEXT NOT NULL,
      "scope" TEXT NOT NULL,
      "code_challenge" TEXT NOT NULL,
      "dpop_jkt" TEXT NOT NULL,
      "client_binding" TEXT,
      "refresh_allowed" INTEGER NOT NULL,
      "expires_at" INTEGER NOT NULL,
      "redeemed_at" INTEGER,
      "redeemed_session_id" TEXT,
      "replay_until" INTEGER,
      "permission_sets" TEXT NOT NULL DEFAULT '{}',
      CONSTRAINT "oauth_authorization_code_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0) AND (length(CAST(dpop_jkt AS BLOB)) = 43) AND (length(CAST(code_challenge AS BLOB)) = 43))),
      CONSTRAINT "oauth_authorization_codes_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "oauth_authorization_codes_permission_sets_shape" CHECK (((json_type(permission_sets) = 'object') AND (length(CAST((permission_sets) AS BLOB)) <= 2097152))),
      CONSTRAINT "oauth_authorization_codes_pkey" PRIMARY KEY (digest),
      CONSTRAINT "oauth_authorization_codes_redeemed_session_id_fkey" FOREIGN KEY (redeemed_session_id) REFERENCES oauth_sessions(id) ON DELETE SET NULL,
      CONSTRAINT "oauth_authorization_codes_source_session_id_fkey" FOREIGN KEY (source_session_id) REFERENCES account_sessions(id) ON DELETE CASCADE,
      CONSTRAINT "oauth_code_redemption_shape" CHECK ((((redeemed_at IS NULL) AND (redeemed_session_id IS NULL) AND (replay_until IS NULL)) OR ((redeemed_at IS NOT NULL) AND (redeemed_at > 0) AND (replay_until IS NOT NULL) AND (replay_until >= redeemed_at))))
    )
    """

    execute """
    CREATE TABLE "oauth_client_assertion_uses" (
      "digest" BLOB NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "oauth_client_assertion_use_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0))),
      CONSTRAINT "oauth_client_assertion_uses_pkey" PRIMARY KEY (digest)
    )
    """

    execute """
    CREATE TABLE "oauth_dpop_uses" (
      "digest" BLOB NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "oauth_dpop_uses_pkey" PRIMARY KEY (digest),
      CONSTRAINT "oauth_proof_use_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0)))
    )
    """

    execute """
    CREATE TABLE "oauth_permission_sets" (
      "nsid" TEXT NOT NULL,
      "document" TEXT NOT NULL,
      "provenance" TEXT NOT NULL,
      "fetched_at" INTEGER NOT NULL,
      "retry_at" INTEGER NOT NULL,
      CONSTRAINT "oauth_permission_set_shape" CHECK (((fetched_at > 0) AND (retry_at >= fetched_at) AND (json_type(document) = 'object') AND (json_type(provenance) = 'object') AND (length(CAST((document) AS BLOB)) <= 524288))),
      CONSTRAINT "oauth_permission_sets_pkey" PRIMARY KEY (nsid)
    )
    """

    execute """
    CREATE TABLE "oauth_pkce_uses" (
      "digest" BLOB NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "oauth_pkce_use_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0))),
      CONSTRAINT "oauth_pkce_uses_pkey" PRIMARY KEY (digest)
    )
    """

    execute """
    CREATE TABLE "oauth_pushed_requests" (
      "digest" BLOB NOT NULL,
      "issuer" TEXT NOT NULL,
      "client_id" TEXT NOT NULL,
      "parameters" TEXT NOT NULL,
      "dpop_jkt" TEXT NOT NULL,
      "client_binding" TEXT,
      "expires_at" INTEGER NOT NULL,
      "permission_sets" TEXT NOT NULL DEFAULT '{}',
      CONSTRAINT "oauth_pushed_request_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0) AND (length(CAST(dpop_jkt AS BLOB)) = 43))),
      CONSTRAINT "oauth_pushed_requests_permission_sets_shape" CHECK (((json_type(permission_sets) = 'object') AND (length(CAST((permission_sets) AS BLOB)) <= 2097152))),
      CONSTRAINT "oauth_pushed_requests_pkey" PRIMARY KEY (digest)
    )
    """

    execute """
    CREATE TABLE "oauth_refresh_uses" (
      "digest" BLOB NOT NULL,
      "session_id" TEXT NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "oauth_refresh_use_shape" CHECK (((length(CAST(digest AS BLOB)) = 32) AND (expires_at > 0))),
      CONSTRAINT "oauth_refresh_uses_pkey" PRIMARY KEY (digest),
      CONSTRAINT "oauth_refresh_uses_session_id_fkey" FOREIGN KEY (session_id) REFERENCES oauth_sessions(id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE "oauth_sessions" (
      "id" TEXT NOT NULL,
      "did" TEXT NOT NULL,
      "source_session_id" TEXT NOT NULL,
      "issuer" TEXT NOT NULL,
      "client_id" TEXT NOT NULL,
      "scope" TEXT NOT NULL,
      "dpop_jkt" TEXT NOT NULL,
      "client_binding" TEXT,
      "refresh_digest" BLOB,
      "expires_at" INTEGER NOT NULL,
      "permission_sets" TEXT NOT NULL DEFAULT '{}',
      CONSTRAINT "oauth_session_shape" CHECK (((length(CAST((id) AS BLOB)) = 43) AND (length(CAST(dpop_jkt AS BLOB)) = 43) AND (expires_at > 0) AND ((refresh_digest IS NULL) OR (length(CAST(refresh_digest AS BLOB)) = 32)))),
      CONSTRAINT "oauth_sessions_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "oauth_sessions_permission_sets_shape" CHECK (((json_type(permission_sets) = 'object') AND (length(CAST((permission_sets) AS BLOB)) <= 2097152))),
      CONSTRAINT "oauth_sessions_pkey" PRIMARY KEY (id),
      CONSTRAINT "oauth_sessions_source_session_id_fkey" FOREIGN KEY (source_session_id) REFERENCES account_sessions(id) ON DELETE CASCADE
    )
    """

    execute """
    CREATE TABLE "plc_registrations" (
      "did" TEXT NOT NULL,
      "operation" TEXT NOT NULL,
      "cid" TEXT NOT NULL,
      "rotation_curve" TEXT NOT NULL,
      "rotation_public_key" BLOB NOT NULL,
      "rotation_envelope" BLOB,
      "confirmed_at" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "completed_at" TEXT,
      "rotation_retired_at" TEXT,
      "submission_started_at" TEXT,
      "retry_token" BLOB,
      "retry_leased_until" TEXT,
      "retry_next_at" TEXT,
      "retry_eligible" INTEGER NOT NULL DEFAULT false,
      CONSTRAINT "completion_requires_confirmation" CHECK (((completed_at IS NULL) OR (confirmed_at IS NOT NULL))),
      CONSTRAINT "plc_registrations_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "plc_registrations_pkey" PRIMARY KEY (did),
      CONSTRAINT "signup_retry_lease_shape" CHECK ((((retry_token IS NULL) AND (retry_leased_until IS NULL) AND (retry_next_at IS NULL)) OR ((retry_token IS NOT NULL) AND (length(CAST(retry_token AS BLOB)) = 32) AND (retry_leased_until IS NOT NULL) AND (retry_next_at IS NOT NULL)))),
      CONSTRAINT "signup_retry_requires_submission" CHECK (((NOT retry_eligible) OR (submission_started_at IS NOT NULL))),
      CONSTRAINT "valid_rotation_key" CHECK ((((rotation_curve) IN (('k256'), ('p256'))) AND (length(CAST(rotation_public_key AS BLOB)) = 33) AND (length(CAST(rotation_envelope AS BLOB)) = 61))),
      CONSTRAINT "valid_rotation_retirement" CHECK ((((rotation_retired_at IS NULL) AND (rotation_envelope IS NOT NULL)) OR ((rotation_retired_at IS NOT NULL) AND (rotation_envelope IS NULL) AND (completed_at IS NOT NULL))))
    )
    """

    execute """
    CREATE TABLE "plc_updates" (
      "did" TEXT NOT NULL,
      "cid" TEXT NOT NULL,
      "previous" TEXT NOT NULL,
      "operation" TEXT NOT NULL,
      "confirmed_at" TEXT,
      "completed_at" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL,
      "signing_curve" TEXT,
      "signing_public_key" BLOB,
      "expected_signing_key" TEXT,
      "signing_envelope" BLOB,
      "authority_curve" TEXT,
      "authority_public_key" BLOB,
      "expected_authority_key" TEXT,
      "authority_envelope" BLOB,
      "recovery_expected_head" TEXT,
      "recovery_deadline" TEXT,
      "recovery_nullified_cids" TEXT,
      "nullified_at" TEXT,
      "nullified_head" TEXT,
      "directory_key_update" INTEGER NOT NULL DEFAULT false,
      CONSTRAINT "nullified_update_shape" CHECK ((((nullified_at IS NULL) AND (nullified_head IS NULL)) OR ((nullified_at IS NOT NULL) AND (nullified_head IS NOT NULL) AND (completed_at IS NULL) AND (signing_envelope IS NULL) AND (authority_envelope IS NULL)))),
      CONSTRAINT "one_pending_key_purpose" CHECK (((recovery_expected_head IS NOT NULL) OR (signing_public_key IS NULL) OR (authority_public_key IS NULL))),
      CONSTRAINT "pending_authority_key_shape" CHECK ((((authority_curve IS NULL) AND (authority_public_key IS NULL) AND (expected_authority_key IS NULL) AND (authority_envelope IS NULL)) OR ((authority_curve IS NOT NULL) AND (authority_curve IN ('k256', 'p256')) AND (authority_public_key IS NOT NULL) AND (length(CAST(authority_public_key AS BLOB)) = 33) AND ((expected_authority_key IS NOT NULL) OR (recovery_expected_head IS NOT NULL)) AND ((authority_envelope IS NULL) OR (length(CAST(authority_envelope AS BLOB)) = 61))))),
      CONSTRAINT "pending_signing_key_shape" CHECK ((((signing_curve IS NULL) AND (signing_public_key IS NULL) AND (expected_signing_key IS NULL) AND (signing_envelope IS NULL)) OR ((signing_curve IS NOT NULL) AND (signing_curve IN ('k256', 'p256')) AND (signing_public_key IS NOT NULL) AND (length(CAST(signing_public_key AS BLOB)) = 33) AND (expected_signing_key IS NOT NULL) AND ((signing_envelope IS NULL) OR (length(CAST(signing_envelope AS BLOB)) = 61))))),
      CONSTRAINT "plc_update_completion_requires_confirmation" CHECK (((completed_at IS NULL) OR (confirmed_at IS NOT NULL))),
      CONSTRAINT "plc_updates_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "plc_updates_pkey" PRIMARY KEY (did, cid),
      CONSTRAINT "recovery_journal_shape" CHECK ((((recovery_expected_head IS NULL) AND (recovery_deadline IS NULL) AND (recovery_nullified_cids IS NULL)) OR ((recovery_expected_head IS NOT NULL) AND (recovery_deadline IS NOT NULL) AND (recovery_nullified_cids IS NOT NULL) AND ((json_array_length(recovery_nullified_cids) >= 1) AND (json_array_length(recovery_nullified_cids) <= 999)))))
    )
    """

    execute """
    CREATE TABLE "record_takedowns" (
      "did" TEXT NOT NULL,
      "path" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      "ref" TEXT,
      CONSTRAINT "record_takedown_ref_size" CHECK (((ref IS NULL) OR (length(CAST(ref AS BLOB)) <= 2000))),
      CONSTRAINT "record_takedowns_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "record_takedowns_pkey" PRIMARY KEY (did, path)
    )
    """

    execute """
    CREATE TABLE "repositories" (
      "did" TEXT NOT NULL,
      "head" BLOB NOT NULL,
      "rev" TEXT NOT NULL,
      "public_key" BLOB NOT NULL,
      "curve" TEXT NOT NULL,
      "status" TEXT NOT NULL DEFAULT 'active',
      "pre_takedown_status" TEXT,
      "takedown_ref" TEXT,
      CONSTRAINT "repositories_head_fkey" FOREIGN KEY (head) REFERENCES blocks(cid),
      CONSTRAINT "repositories_pkey" PRIMARY KEY (did),
      CONSTRAINT "repository_curve" CHECK (((curve) IN ('p256', 'k256'))),
      CONSTRAINT "repository_public_key" CHECK ((length(CAST(public_key AS BLOB)) = 33)),
      CONSTRAINT "repository_status" CHECK (((status) IN ('active', 'deactivated', 'takendown', 'suspended'))),
      CONSTRAINT "repository_takedown_ref_size" CHECK (((takedown_ref IS NULL) OR (length(CAST(takedown_ref AS BLOB)) <= 2000))),
      CONSTRAINT "repository_takedown_state" CHECK (((((status) = 'takendown') AND (pre_takedown_status IS NOT NULL) AND ((pre_takedown_status) IN ('active', 'deactivated', 'suspended'))) OR (((status) <> 'takendown') AND (pre_takedown_status IS NULL) AND (takedown_ref IS NULL))))
    )
    """

    execute """
    CREATE TABLE "repository_blobs" (
      "did" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      "backend" TEXT NOT NULL,
      "mime_type" TEXT NOT NULL,
      "size" INTEGER NOT NULL,
      "staged_at" TEXT NOT NULL,
      CONSTRAINT "blob_backend" CHECK ((backend IN ('postgres', 's3'))),
      CONSTRAINT "blob_mime_type" CHECK (((length(mime_type) >= 3) AND (length(mime_type) <= 255))),
      CONSTRAINT "blob_raw_cid" CHECK (((length(CAST(cid AS BLOB)) = 36) AND (substr(cid, 1, 4) = X'01551220'))),
      CONSTRAINT "blob_size" CHECK (((size >= 0) AND (size <= 5242880))),
      CONSTRAINT "repository_blobs_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_blobs_pkey" PRIMARY KEY (did, cid)
    )
    """

    execute """
    CREATE TABLE "repository_block_refs" (
      "did" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      "revision_count" INTEGER NOT NULL,
      CONSTRAINT "positive_revision_count" CHECK ((revision_count > 0)),
      CONSTRAINT "repository_block_refs_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_block_refs_pkey" PRIMARY KEY (did, cid)
    )
    """

    execute """
    CREATE TABLE "repository_credentials" (
      "did" TEXT NOT NULL,
      "password_hash" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL,
      CONSTRAINT "password_hash_format" CHECK (((password_hash LIKE '$argon2id$%') AND (length(CAST(password_hash AS BLOB)) <= 512))),
      CONSTRAINT "repository_credentials_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_credentials_pkey" PRIMARY KEY (did)
    )
    """

    execute """
    CREATE TABLE "repository_events" (
      "seq" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      "did" TEXT NOT NULL,
      "kind" TEXT NOT NULL,
      "payload" BLOB NOT NULL,
      "time" TEXT NOT NULL,
      CONSTRAINT "valid_kind" CHECK ((kind IN ('commit', 'sync', 'account', 'identity')))
    )
    """

    execute """
    CREATE TABLE "repository_identities" (
      "did" TEXT NOT NULL,
      "fingerprint" BLOB NOT NULL,
      "handle" TEXT NOT NULL,
      CONSTRAINT "fingerprint_size" CHECK ((length(CAST(fingerprint AS BLOB)) = 32)),
      CONSTRAINT "repository_identities_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_identities_pkey" PRIMARY KEY (did)
    )
    """

    execute """
    CREATE TABLE "repository_keys" (
      "did" TEXT NOT NULL,
      "envelope" BLOB NOT NULL,
      CONSTRAINT "key_envelope_length" CHECK ((length(CAST(envelope AS BLOB)) = 61)),
      CONSTRAINT "repository_keys_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_keys_pkey" PRIMARY KEY (did)
    )
    """

    execute """
    CREATE TABLE "repository_records" (
      "did" TEXT NOT NULL,
      "path" TEXT NOT NULL,
      "cid" BLOB NOT NULL,
      CONSTRAINT "repository_records_cid_fkey" FOREIGN KEY (cid) REFERENCES blocks(cid),
      CONSTRAINT "repository_records_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_records_pkey" PRIMARY KEY (did, path)
    )
    """

    execute """
    CREATE TABLE "repository_revisions" (
      "did" TEXT NOT NULL,
      "rev" TEXT NOT NULL,
      "head" BLOB NOT NULL,
      "blocks" TEXT NOT NULL,
      "inserted_at" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f000', 'now')),
      "signing_curve" TEXT NOT NULL,
      "signing_public_key" BLOB NOT NULL,
      CONSTRAINT "repository_revisions_did_fkey" FOREIGN KEY (did) REFERENCES repositories(did) ON DELETE CASCADE,
      CONSTRAINT "repository_revisions_head_fkey" FOREIGN KEY (head) REFERENCES blocks(cid),
      CONSTRAINT "repository_revisions_pkey" PRIMARY KEY (did, rev),
      CONSTRAINT "revision_signing_key" CHECK ((((signing_curve) IN ('k256', 'p256')) AND (length(CAST(signing_public_key AS BLOB)) = 33)))
    )
    """

    execute """
    CREATE TABLE "request_rate_buckets" (
      "digest" BLOB NOT NULL,
      "count" INTEGER NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "rate_bucket_count" CHECK ((count > 0)),
      CONSTRAINT "rate_bucket_digest_length" CHECK ((length(CAST(digest AS BLOB)) = 32)),
      CONSTRAINT "rate_bucket_expiration" CHECK ((expires_at > 0)),
      CONSTRAINT "request_rate_buckets_pkey" PRIMARY KEY (digest)
    )
    """

    execute """
    CREATE TABLE "reserved_signing_keys" (
      "public_key" TEXT NOT NULL,
      "did" TEXT,
      "envelope" BLOB NOT NULL,
      "inserted_at" TEXT NOT NULL,
      CONSTRAINT "reserved_signing_key_shape" CHECK (((length(CAST(envelope AS BLOB)) = 61) AND (length(CAST(public_key AS BLOB)) <= 256) AND ((did IS NULL) OR (length(CAST(did AS BLOB)) <= 2048)))),
      CONSTRAINT "reserved_signing_keys_pkey" PRIMARY KEY (public_key)
    )
    """

    execute """
    CREATE TABLE "service_token_uses" (
      "digest" BLOB NOT NULL,
      "expires_at" INTEGER NOT NULL,
      CONSTRAINT "service_token_digest_length" CHECK ((length(CAST(digest AS BLOB)) = 32)),
      CONSTRAINT "service_token_expiration" CHECK ((expires_at > 0)),
      CONSTRAINT "service_token_uses_pkey" PRIMARY KEY (digest)
    )
    """

    execute """
    CREATE INDEX account_passkey_challenges_expires_at_digest_index ON account_passkey_challenges (expires_at, digest)
    """

    execute """
    CREATE INDEX account_passkey_challenges_source_session_id_index ON account_passkey_challenges (source_session_id)
    """

    execute """
    CREATE UNIQUE INDEX account_passkey_users_user_handle_index ON account_passkey_users (user_handle)
    """

    execute """
    CREATE UNIQUE INDEX account_passkeys_credential_id_index ON account_passkeys (credential_id)
    """

    execute """
    CREATE INDEX account_passkeys_did_index ON account_passkeys (did)
    """

    execute """
    CREATE UNIQUE INDEX account_profiles_email_index ON account_profiles (email)
    """

    execute """
    CREATE UNIQUE INDEX account_profiles_handle_index ON account_profiles (handle)
    """

    execute """
    CREATE UNIQUE INDEX account_profiles_password_reset_digest_index ON account_profiles (password_reset_digest)
    """

    execute """
    CREATE INDEX account_sessions_app_password_id_index ON account_sessions (app_password_id)
    """

    execute """
    CREATE INDEX account_sessions_did_index ON account_sessions (did)
    """

    execute """
    CREATE INDEX account_sessions_expires_at_index ON account_sessions (expires_at)
    """

    execute """
    CREATE INDEX account_sessions_passkey_id_index ON account_sessions (passkey_id)
    """

    execute """
    CREATE UNIQUE INDEX app_passwords_did_digest_index ON app_passwords (did, digest)
    """

    execute """
    CREATE UNIQUE INDEX app_passwords_did_name_index ON app_passwords (did, name)
    """

    execute """
    CREATE INDEX blob_cleanup_jobs_queued_at_index ON blob_cleanup_jobs (queued_at)
    """

    execute """
    CREATE INDEX blob_references_did_cid_index ON blob_references (did, cid)
    """

    execute """
    CREATE INDEX blocks_inserted_at_cid_index ON blocks (inserted_at, cid)
    """

    execute """
    CREATE INDEX event_revision_dependencies_did_head_index ON event_revision_dependencies (did, head)
    """

    execute """
    CREATE UNIQUE INDEX handle_change_reservations_did_index ON handle_change_reservations (did)
    """

    execute """
    CREATE INDEX invite_codes_created_by_index ON invite_codes (created_by)
    """

    execute """
    CREATE INDEX invite_codes_for_account_index ON invite_codes (for_account)
    """

    execute """
    CREATE INDEX invite_codes_owner_recent ON invite_codes (for_account, inserted_at DESC, code)
    """

    execute """
    CREATE INDEX invite_codes_recent ON invite_codes (inserted_at DESC, code)
    """

    execute """
    CREATE INDEX invite_codes_usage ON invite_codes (((use_count - remaining)) DESC, inserted_at DESC, code)
    """

    execute """
    CREATE INDEX invite_uses_code_index ON invite_uses (code)
    """

    execute """
    CREATE INDEX moderation_audit_entries_did_id_index ON moderation_audit_entries (did, id)
    """

    execute """
    CREATE INDEX oauth_access_tokens_expires_at_digest_index ON oauth_access_tokens (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_access_tokens_session_id_index ON oauth_access_tokens (session_id)
    """

    execute """
    CREATE INDEX oauth_authorization_codes_did_index ON oauth_authorization_codes (did)
    """

    execute """
    CREATE INDEX oauth_authorization_codes_expires_at_digest_index ON oauth_authorization_codes (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_authorization_codes_redeemed_session_id_index ON oauth_authorization_codes (redeemed_session_id)
    """

    execute """
    CREATE INDEX oauth_authorization_codes_replay_until_digest_index ON oauth_authorization_codes (replay_until, digest)
    """

    execute """
    CREATE INDEX oauth_authorization_codes_source_session_id_index ON oauth_authorization_codes (source_session_id)
    """

    execute """
    CREATE INDEX oauth_client_assertion_uses_expires_at_digest_index ON oauth_client_assertion_uses (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_dpop_uses_expires_at_digest_index ON oauth_dpop_uses (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_permission_sets_fetched_at_nsid_index ON oauth_permission_sets (fetched_at, nsid)
    """

    execute """
    CREATE INDEX oauth_pkce_uses_expires_at_digest_index ON oauth_pkce_uses (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_pushed_requests_expires_at_digest_index ON oauth_pushed_requests (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_refresh_uses_expires_at_digest_index ON oauth_refresh_uses (expires_at, digest)
    """

    execute """
    CREATE INDEX oauth_refresh_uses_session_id_index ON oauth_refresh_uses (session_id)
    """

    execute """
    CREATE INDEX oauth_sessions_did_index ON oauth_sessions (did)
    """

    execute """
    CREATE INDEX oauth_sessions_expires_at_id_index ON oauth_sessions (expires_at, id)
    """

    execute """
    CREATE INDEX oauth_sessions_key_check_cursor ON oauth_sessions (client_id, id) WHERE (client_binding IS NOT NULL)
    """

    execute """
    CREATE UNIQUE INDEX oauth_sessions_refresh_digest_index ON oauth_sessions (refresh_digest)
    """

    execute """
    CREATE INDEX oauth_sessions_source_session_id_index ON oauth_sessions (source_session_id)
    """

    execute """
    CREATE INDEX plc_registrations_cleanup_candidates ON plc_registrations (inserted_at, did) WHERE ((submission_started_at IS NULL) AND (confirmed_at IS NULL) AND (completed_at IS NULL))
    """

    execute """
    CREATE INDEX plc_registrations_retry_due ON plc_registrations (COALESCE(retry_next_at, submission_started_at), did) WHERE ((submission_started_at IS NOT NULL) AND (completed_at IS NULL))
    """

    execute """
    CREATE INDEX plc_registrations_retry_eligible_due ON plc_registrations (COALESCE(retry_next_at, submission_started_at), did) WHERE (retry_eligible AND (completed_at IS NULL))
    """

    execute """
    CREATE UNIQUE INDEX plc_updates_one_pending ON plc_updates (did) WHERE ((completed_at IS NULL) AND (nullified_at IS NULL))
    """

    execute """
    CREATE UNIQUE INDEX plc_updates_one_retained_authority_key ON plc_updates (did) WHERE (authority_envelope IS NOT NULL)
    """

    execute """
    CREATE UNIQUE INDEX plc_updates_one_retained_signing_key ON plc_updates (did) WHERE (signing_envelope IS NOT NULL)
    """

    execute """
    CREATE INDEX repository_blobs_staged_at_index ON repository_blobs (staged_at)
    """

    execute """
    CREATE INDEX repository_block_refs_cid_index ON repository_block_refs (cid)
    """

    execute """
    CREATE INDEX repository_records_collection_did_index ON repository_records (substr(path, 1, instr(path, '/') - 1), did COLLATE BINARY)
    """

    execute """
    CREATE INDEX repository_revisions_did_inserted_at_rev_index ON repository_revisions (did, inserted_at, rev)
    """

    execute """
    CREATE INDEX request_rate_buckets_expires_at_index ON request_rate_buckets (expires_at)
    """

    execute """
    CREATE UNIQUE INDEX reserved_signing_keys_did_index ON reserved_signing_keys (did)
    """

    execute """
    CREATE INDEX service_token_uses_expires_at_index ON service_token_uses (expires_at)
    """

    execute """
    INSERT INTO event_retention_state (id, cursor_floor) VALUES (1, 0)
    """

    execute """
    CREATE TRIGGER atoll_revision_blocks_insert AFTER INSERT ON repository_revisions
    BEGIN
    INSERT INTO repository_block_refs (did, cid, revision_count)
    SELECT NEW.did, unhex(value), 1 FROM json_each(NEW.blocks) WHERE true GROUP BY value
    ON CONFLICT (did, cid) DO UPDATE SET revision_count = repository_block_refs.revision_count + 1;
    END
    """

    execute """
    CREATE TRIGGER atoll_revision_blocks_delete AFTER DELETE ON repository_revisions
    BEGIN
    DELETE FROM repository_block_refs WHERE did = OLD.did AND revision_count = 1
      AND cid IN (SELECT unhex(value) FROM json_each(OLD.blocks));
    UPDATE repository_block_refs SET revision_count = revision_count - 1
      WHERE did = OLD.did AND cid IN (SELECT unhex(value) FROM json_each(OLD.blocks));
    END
    """

    execute """
    CREATE TRIGGER atoll_revision_blocks_update AFTER UPDATE ON repository_revisions
    BEGIN
    DELETE FROM repository_block_refs WHERE did = OLD.did AND revision_count = 1
      AND cid IN (SELECT unhex(value) FROM json_each(OLD.blocks));
    UPDATE repository_block_refs SET revision_count = revision_count - 1
      WHERE did = OLD.did AND cid IN (SELECT unhex(value) FROM json_each(OLD.blocks));
    INSERT INTO repository_block_refs (did, cid, revision_count)
    SELECT NEW.did, unhex(value), 1 FROM json_each(NEW.blocks) WHERE true GROUP BY value
    ON CONFLICT (did, cid) DO UPDATE SET revision_count = repository_block_refs.revision_count + 1;
    END
    """
  end

  def down do
    execute ~s(DROP TABLE "plc_registrations")
    execute ~s(DROP TABLE "repository_records")
    execute ~s(DROP TABLE "record_takedowns")
    execute ~s(DROP TABLE "account_passkey_challenges")
    execute ~s(DROP TABLE "repository_credentials")
    execute ~s(DROP TABLE "repository_identities")
    execute ~s(DROP TABLE "oauth_refresh_uses")
    execute ~s(DROP TABLE "invite_uses")
    execute ~s(DROP TABLE "event_retention_state")
    execute ~s(DROP TABLE "handle_change_reservations")
    execute ~s(DROP TABLE "repository_keys")
    execute ~s(DROP TABLE "oauth_client_assertion_uses")
    execute ~s(DROP TABLE "request_rate_buckets")
    execute ~s(DROP TABLE "blob_takedowns")
    execute ~s(DROP TABLE "account_preferences")
    execute ~s(DROP TABLE "moderation_audit_entries")
    execute ~s(DROP TABLE "account_profiles")
    execute ~s(DROP TABLE "repository_revisions")
    execute ~s(DROP TABLE "oauth_dpop_uses")
    execute ~s(DROP TABLE "oauth_access_tokens")
    execute ~s(DROP TABLE "blob_cleanup_jobs")
    execute ~s(DROP TABLE "reserved_signing_keys")
    execute ~s(DROP TABLE "service_token_uses")
    execute ~s(DROP TABLE "imported_plc_rotation_keys")
    execute ~s(DROP TABLE "blob_references")
    execute ~s(DROP TABLE "account_totp_factors")
    execute ~s(DROP TABLE "repository_block_refs")
    execute ~s(DROP TABLE "event_revision_dependencies")
    execute ~s(DROP TABLE "oauth_authorization_codes")
    execute ~s(DROP TABLE "repository_blobs")
    execute ~s(DROP TABLE "oauth_permission_sets")
    execute ~s(DROP TABLE "identity_refresh_leases")
    execute ~s(DROP TABLE "oauth_pkce_uses")
    execute ~s(DROP TABLE "oauth_pushed_requests")
    execute ~s(DROP TABLE "plc_updates")
    execute ~s(DROP TABLE "oauth_sessions")
    execute ~s(DROP TABLE "invite_codes")
    execute ~s(DROP TABLE "repository_events")
    execute ~s(DROP TABLE "account_sessions")
    execute ~s(DROP TABLE "app_passwords")
    execute ~s(DROP TABLE "account_passkeys")
    execute ~s(DROP TABLE "account_passkey_users")
    execute ~s(DROP TABLE "repositories")
    execute ~s(DROP TABLE "blocks")
  end
end
