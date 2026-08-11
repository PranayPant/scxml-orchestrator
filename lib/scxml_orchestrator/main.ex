defmodule ScxmlOrchestrator.Main do
  @moduledoc """
  Command-line entrypoint (escript) for the SCXML orchestrator.

  Provides a lightweight sandbox so consumers can "play around" with the
  engine from the shell without writing any Elixir. This is intentionally a
  minimal playground; production consumption happens through the library API
  (see `ScxmlEngine`).

  ## Usage

      ./scxml_orchestrator --file path/to/chart.json [--event NAME]... \\
                           [--datamodel '{"key":"value"}'] [--instance-id ID]

  Loads the chart, starts an instance, fires each `--event` in order, and
  prints the resulting active configuration and datamodel after each event.

  ## Exit codes

    * `0` — success
    * `2` — bad usage (missing/invalid arguments)
    * `3` — could not load/run the document
    * `4` — event dispatch failed
  """

  @exit_ok 0
  @exit_usage 2
  @exit_load 3
  @exit_event 4

  @type opts :: %{
          file: String.t(),
          events: [String.t()],
          datamodel: map(),
          instance_id: String.t() | nil
        }

  @doc """
  Entrypoint invoked by the escript. Parses `argv`, runs the pipeline, then
  halts with a process exit code. A thin wrapper around `execute/1`.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    case execute(argv) do
      {:help} ->
        IO.puts(usage())
        halt(@exit_ok)

      {:ok, _result} ->
        halt(@exit_ok)

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, usage())
        halt(@exit_usage)

      {:load_error, message} ->
        IO.puts(:stderr, "error: #{message}")
        halt(@exit_load)

      {:event_error, message} ->
        IO.puts(:stderr, "error: #{message}")
        halt(@exit_event)
    end
  end

  @doc """
  Testable core: parse `argv` and drive the engine without halting.

  Returns `{:help}`, `{:ok, result}`, `{:error, message}` (usage error),
  `{:load_error, message}`, or `{:event_error, message}`.
  """
  @spec execute([String.t()]) ::
          {:help}
          | {:ok, term()}
          | {:error, String.t()}
          | {:load_error, String.t()}
          | {:event_error, String.t()}
  def execute(argv) do
    case parse_args(argv) do
      {:help} -> {:help}
      {:error, message} -> {:error, message}
      {:ok, opts} -> run(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Argument parsing
  # ---------------------------------------------------------------------------

  @doc false
  @spec parse_args([String.t()]) :: {:ok, opts()} | {:error, String.t()} | {:help}
  def parse_args(argv) do
    case do_parse(argv, %{file: nil, events: [], datamodel: %{}, instance_id: nil}) do
      :help -> {:help}
      {:ok, opts} -> validate(opts)
      {:error, message} -> {:error, message}
    end
  end

  defp do_parse([], opts), do: {:ok, opts}

  defp do_parse(["--help" | _], _opts), do: :help

  defp do_parse(["--file", file | rest], opts) when is_binary(file) do
    do_parse(rest, %{opts | file: file})
  end

  defp do_parse(["--event", name | rest], opts) when is_binary(name) do
    do_parse(rest, %{opts | events: opts.events ++ [name]})
  end

  defp do_parse(["--datamodel", json | rest], opts) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, datamodel} when is_map(datamodel) -> do_parse(rest, %{opts | datamodel: datamodel})
      _ -> {:error, "invalid --datamodel JSON (must be an object)"}
    end
  end

  defp do_parse(["--instance-id", id | rest], opts) when is_binary(id) do
    do_parse(rest, %{opts | instance_id: id})
  end

  defp do_parse([flag | _], _opts), do: {:error, "unrecognized argument: #{flag}"}

  @spec validate(opts()) :: {:ok, opts()} | {:error, String.t()}
  defp validate(%{file: nil}), do: {:error, "missing required --file <chart.json>"}

  defp validate(%{file: file}) when not is_binary(file) or file == "" do
    {:error, "--file must be a non-empty path"}
  end

  defp validate(opts), do: {:ok, opts}

  # ---------------------------------------------------------------------------
  # Execution
  # ---------------------------------------------------------------------------

  @spec run(opts()) ::
          {:ok, term()} | {:load_error, String.t()} | {:event_error, String.t()}
  defp run(%{file: file} = opts) do
    with {:ok, json} <- read_file(file),
         {:ok, instance} <- start_instance(opts, json) do
      dispatch_events(opts, instance)
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:load_error, "cannot read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp start_instance(opts, json) do
    run_opts = maybe_put([initial_datamodel: opts.datamodel], :instance_id, opts.instance_id)

    case ScxmlEngine.run(json, run_opts) do
      {:ok, pid} ->
        {:ok, %{pid: pid, instance_id: Keyword.get(run_opts, :instance_id)}}

      {:error, reason} ->
        {:load_error, "could not load/run document: #{inspect(reason)}"}
    end
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: Keyword.put(list, key, value)

  defp dispatch_events(opts, %{pid: pid} = state) do
    result =
      Enum.reduce_while(opts.events, :ok, fn event, :ok ->
        IO.puts("> event: #{event}")

        case ScxmlEngine.send_event(pid, event) do
          :ok ->
            print_state(state)
            {:cont, :ok}

          other ->
            {:halt, {:event_error, "event #{inspect(event)} dispatch returned #{inspect(other)}"}}
        end
      end)

    case result do
      {:event_error, message} ->
        {:event_error, message}

      :ok ->
        if opts.events == [] do
          IO.puts("entry state (no events dispatched, instance is running)")
        end

        print_state(state)
        IO.puts("  done? #{ScxmlEngine.done?(pid)}")
        {:ok, %{pid: pid, configuration: config(pid), datamodel: ScxmlEngine.datamodel(pid)}}
    end
  end

  defp config(pid), do: pid |> ScxmlEngine.active_configuration() |> MapSet.to_list() |> Enum.sort()

  defp print_state(%{pid: pid}) do
    IO.puts("  active_configuration: #{inspect(config(pid))}")
    IO.puts("  datamodel: #{inspect(ScxmlEngine.datamodel(pid))}")
  end

  @spec usage() :: String.t()
  def usage do
    """
    usage: scxml_orchestrator --file <chart.json> [options]

    options:
      --file <path>        path to the SCXML AST JSON document (required)
      --event <name>       dispatches an event (repeat for multiple, in order)
      --datamodel <json>   initial datamodel as a JSON object
      --instance-id <id>   instance id to register under (defaults to graph id)
      --help               show this help

    exit codes:
      0  success
      2  bad usage
      3  could not load/run the document
      4  event dispatch failed
    """
  end

  defp halt(code), do: System.halt(code)
end
