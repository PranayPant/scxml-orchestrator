defmodule ScxmlOrchestrator.MainTest do
  use ExUnit.Case, async: false

  alias ScxmlOrchestrator.Main

  @moduletag timeout: 5000

  describe "parse_args/1" do
    test "parses --file, repeated --event, --datamodel and --instance-id" do
      args = [
        "--file",
        "chart.json",
        "--event",
        "next",
        "--event",
        "ready",
        "--datamodel",
        ~s({"speed": 3}),
        "--instance-id",
        "my_inst"
      ]

      assert {:ok, opts} = Main.parse_args(args)
      assert opts.file == "chart.json"
      assert opts.events == ["next", "ready"]
      assert opts.datamodel == %{"speed" => 3}
      assert opts.instance_id == "my_inst"
    end

    test "defaults events/datamodel/instance_id" do
      assert {:ok, opts} = Main.parse_args(["--file", "chart.json"])
      assert opts.events == []
      assert opts.datamodel == %{}
      assert opts.instance_id == nil
    end

    test "--help returns {:help}" do
      assert Main.parse_args(["--help"]) == {:help}
    end

    test "missing --file is a usage error" do
      assert {:error, message} = Main.parse_args(["--event", "next"])
      assert message =~ "missing required --file"
    end

    test "unknown flag is a usage error" do
      assert {:error, message} = Main.parse_args(["--nope"])
      assert message =~ "unrecognized argument"
    end

    test "invalid --datamodel is a usage error" do
      assert {:error, message} = Main.parse_args(["--file", "a.json", "--datamodel", "not-json"])
      assert message =~ "invalid --datamodel"
    end
  end

  describe "execute/1" do
    test "loads a fixture, dispatches events, and reports the active configuration" do
      fixture = Path.join(fixtures_dir(), "traffic_light.json")

      assert {:ok, result} = Main.execute(["--file", fixture, "--event", "next"])
      assert result.configuration == ["green"]
      assert result.datamodel["data"]["color"] == "green"
    end

    test "no events still starts the instance at entry state" do
      fixture = Path.join(fixtures_dir(), "traffic_light.json")
      assert {:ok, result} = Main.execute(["--file", fixture])
      assert result.configuration == ["red"]
    end

    test "missing file is a load error" do
      assert {:load_error, message} = Main.execute(["--file", "does_not_exist.json"])
      assert message =~ "cannot read"
    end

    test "invalid document is a load error" do
      tmp = Path.join(System.tmp_dir!(), "scxml_main_bad_#{System.unique_integer([:positive])}.json")
      File.write!(tmp, "not valid json")

      try do
        assert {:load_error, message} = Main.execute(["--file", tmp])
        assert message =~ "could not load/run document"
      after
        File.rm(tmp)
      end
    end

    test "--help returns {:help}" do
      assert Main.execute(["--help"]) == {:help}
    end
  end

  describe "usage/0" do
    test "mentions the key flags" do
      usage = Main.usage()
      assert usage =~ "--file"
      assert usage =~ "--event"
      assert usage =~ "--datamodel"
    end
  end

  defp fixtures_dir do
    Path.expand("../fixtures", __DIR__)
  end
end
