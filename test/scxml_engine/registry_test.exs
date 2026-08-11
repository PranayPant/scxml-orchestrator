defmodule ScxmlEngine.RegistryTest do
  use ExUnit.Case, async: false

  alias ScxmlEngine.Registry

  test "register + lookup roundtrip" do
    Registry.register("registry_key_1", self())
    assert Registry.lookup("registry_key_1") == {:ok, self()}
  end

  test "lookup returns :error for an unknown key" do
    assert Registry.lookup("no_such_key_xyz") == :error
  end

  test "instances/0 enumerates registered pairs" do
    Registry.register("registry_key_2", self())
    assert Enum.any?(Registry.instances(), fn {k, _} -> k == "registry_key_2" end)
  end
end
