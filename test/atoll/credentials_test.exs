defmodule Atoll.Accounts.CredentialsTest do
  use Atoll.DataCase, async: true
  alias Atoll.{Repositories, SigningKey}
  alias Atoll.Accounts.{Credential, Credentials}
  @did "did:plc:credentials"
  @password "correct horse battery staple"

  setup do
    {:ok, _} = Repositories.create(@did, SigningKey.generate())
    :ok
  end

  test "stores an Argon2id hash and returns only the verified DID" do
    assert Credentials.create(@did, @password) == {:ok, %{did: @did}}
    credential = Repo.get!(Credential, @did)
    assert credential.password_hash =~ "$argon2id$"
    refute credential.password_hash =~ @password
    refute inspect(credential) =~ credential.password_hash
    assert Credentials.verify(@did, @password) == {:ok, %{did: @did}}
    assert Credentials.verify(@did, "incorrect password") == {:error, :invalid_credentials}
  end

  test "salts are independent and duplicate creation never changes the password" do
    other = "did:plc:credentialsother"
    {:ok, _} = Repositories.create(other, SigningKey.generate())
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, _} = Credentials.create(other, @password)
    refute Repo.get!(Credential, @did).password_hash == Repo.get!(Credential, other).password_hash
    assert Credentials.create(@did, "replacement password") == {:error, :credential_exists}
    assert Credentials.verify(@did, @password) == {:ok, %{did: @did}}
    assert Credentials.verify(@did, "replacement password") == {:error, :invalid_credentials}
  end

  test "missing credentials and incorrect passwords have the same error" do
    assert Credentials.verify(@did, @password) == {:error, :invalid_credentials}
    assert Credentials.verify("did:plc:missing", @password) == {:error, :invalid_credentials}
    assert Credentials.create("did:plc:missing", @password) == {:error, :not_found}
    refute Repo.exists?(Credential)
  end

  test "bounds passwords without trimming or truncation" do
    for password <- [nil, 123, "short", <<255, 0, 0, 0, 0, 0, 0, 0>>, String.duplicate("x", 1025)] do
      assert Credentials.create(@did, password) == {:error, :invalid_credentials}
      assert Credentials.verify(@did, password) == {:error, :invalid_credentials}
    end

    password = " " <> String.duplicate("é", 511) <> " "
    assert Credentials.create(@did, password) == {:ok, %{did: @did}}
    assert Credentials.verify(@did, password) == {:ok, %{did: @did}}
    assert Credentials.verify(@did, String.trim(password)) == {:error, :invalid_credentials}
    assert Credentials.create(nil, @password) == {:error, :invalid_credentials}
    assert Credentials.verify([@did], @password) == {:error, :invalid_credentials}
  end

  test "outer rollback removes credentials and status remains a separate policy" do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               {:ok, _} = Credentials.create(@did, @password)
               Repo.rollback(:abort)
             end)

    refute Repo.exists?(Credential)
    {:ok, _} = Credentials.create(@did, @password)
    {:ok, _} = Repositories.set_status(@did, :deactivated)
    assert Credentials.verify(@did, @password) == {:ok, %{did: @did}}
    assert Repositories.get_active_head(@did) == {:error, {:repo_inactive, :deactivated}}
  end
end
