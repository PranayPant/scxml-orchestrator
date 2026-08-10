defmodule ScxmlEngine.TestSupport.Fixtures do
  @moduledoc """
  Helper for loading parser-shaped AST JSON fixture files from
  `test/fixtures/`.
  """

  @fixtures_dir Path.expand("../fixtures", __DIR__)

  @doc """
  Load a fixture file's raw JSON string by name (without the `.json` extension).
  """
  @spec load_json(String.t()) :: String.t()
  def load_json(name) do
    @fixtures_dir
    |> Path.join(name <> ".json")
    |> File.read!()
  end

  @doc """
  Load and decode a fixture file into a map.
  """
  @spec decode(String.t()) :: map()
  def decode(name) do
    name |> load_json() |> Jason.decode!()
  end
end
