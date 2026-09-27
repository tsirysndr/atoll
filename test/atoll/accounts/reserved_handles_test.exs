defmodule Atoll.Accounts.ReservedHandlesTest do
  use Atoll.DataCase, async: false
  alias Atoll.Accounts.ReservedHandles

  setup do
    prior = Application.fetch_env(:atoll, :pds)

    Application.put_env(:atoll, :pds,
      did: "did:web:pds.example.com",
      available_user_domains: [".example.com"]
    )

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:atoll, :pds, value)
        :error -> Application.delete_env(:atoll, :pds)
      end
    end)

    :ok
  end

  test "blocks reserved labels under hosted domains only" do
    for label <- ["www", "admin", "mail", "pds", "cdn"] do
      assert ReservedHandles.blocked?(label <> ".example.com")
    end

    refute ReservedHandles.blocked?("alice.example.com")
    refute ReservedHandles.blocked?("www.unrelated.com")
    refute ReservedHandles.blocked?("www.deep.example.com")
    refute ReservedHandles.blocked?(nil)
  end

  test "an account already holding the reserved handle keeps claiming it" do
    did = "did:plc:reservedowner"
    {:ok, _} = Atoll.Repositories.create(did, Atoll.SigningKey.generate())
    Repo.insert!(%Atoll.Accounts.Profile{did: did, handle: "www.example.com"})
    refute ReservedHandles.blocked?("www.example.com", did)
    assert ReservedHandles.blocked?("www.example.com", "did:plc:someoneelse")
    assert ReservedHandles.blocked?("cdn.example.com", did)
  end

  test "the reserved list is configurable and validated" do
    assert ReservedHandles.list_from_env!(nil) == ReservedHandles.default()
    assert ReservedHandles.list_from_env!("") == []
    assert ReservedHandles.list_from_env!("Foo, bar,foo") == ["foo", "bar"]

    for value <- ["under_score", "a..b", "-lead", ","] do
      assert_raise ArgumentError, fn -> ReservedHandles.list_from_env!(value) end
    end

    prior = Application.get_env(:atoll, :reserved_handles)
    Application.put_env(:atoll, :reserved_handles, ["custom"])

    on_exit(fn ->
      if prior,
        do: Application.put_env(:atoll, :reserved_handles, prior),
        else: Application.delete_env(:atoll, :reserved_handles)
    end)

    assert ReservedHandles.blocked?("custom.example.com")
    refute ReservedHandles.blocked?("www.example.com")
  end
end
