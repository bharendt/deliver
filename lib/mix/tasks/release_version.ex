defmodule Mix.Tasks.Release.Version do
  use Mix.Task

  @shortdoc "Displays or modifies the release version"

  @moduledoc """
  Displays the release version or modifies it before building the release.
  This task can be used in conjunction with the `release` task to modify
  the version for the release / upgrade. The compiled files must be cleaned
  before and the release task must be executed after. Increasing version
  and appending metadata to the version can be combined, e.g:

  `mix do clean, release.version increase minor append-git-revision append-branch, release`

  To automatically append metadata, you can set the `$AUTO_VERSION` environment variable.

  # Usage:

    * mix release.version [show]
    * mix do clean, release.version set <new-version> [Option], release
    * mix do clean, release.version increase [patch|minor|major] [version] [Option], release
    * mix do clean, release.version [append-][git-]revision|commit-count|branch [Option], release
    * mix do clean, release.version [append-][build-]date [Option], release

  ## Actions
    * `show` Displays the current release version.
    * `append-git-revision` Appends sha1 git revision of current HEAD
    * `append-git-commit-count` Appends the number of commits across all branches
    * `append-git-branch` Appends the current branch that is built
    * `append-build-date` Appends the build date as YYYYMMDD
    * `increase` Increases the release version
      - `patch` Increases the patch version (default). The last part of a tripartite version.
      - `minor` Increases the minor version. The middle part of a tripartite version.
      - `major` Increases the major version. The first part of a tripartite version.

  ## Options
    * `-V`, `--verbose` Verbose output
    * `-Q`, `--quiet`   Print only errors while modifying version
    * `-D`, `--dry-run` Print only new version without changing it


  ## Example

    `MIX_ENV=prod mix do clean, release.version append-git-revision, release`
  """
  @spec run(OptionParser.argv) :: :ok
  def run(args) do
    case OptionParser.parse(args, aliases: [V: :verbose, Q: :quiet, D: :dry_run], switches: [verbose: :boolean, quiet: :boolean, dry_run: :boolean]) do
      {switches, args, []} ->
        case parse_args(args) do
          {:modify, modification_functions} ->
            case Keyword.get(switches, :dry_run, false) do
              true ->
                {:modified, new_version} = modify_version({:modify, modification_functions}, old_version = get_version)
                Mix.Shell.IO.info "Would update version from #{old_version} to #{new_version}"
              false -> update_release_version(modification_functions, switches)
            end
          :show -> print_version
          {:error, message} -> Mix.raise message
        end
      {_, _, [{unknown_option, _}]} -> Mix.raise "Error: Unknown argument #{unknown_option} for 'release.version' task."
      {_, _, unknown_options} ->
        unknown_options = unknown_options |> Enum.map(&(elem(&1, 0))) |> Enum.join(", ")
        Mix.raise "Error: Unknown arguments #{unknown_options} for 'release.version' task."
    end
  end

  @privdoc """
    Sets the release version to the new value by using the passed update funs.
  """
  @spec update_release_version(modification_functions::[modification_fun], options::[String.t]) :: new_version::String.t
  defp update_release_version(modification_functions, options) do
    {old_version, new_version} = Agent.get_and_update Mix.ProjectStack, fn(state) ->
      [root=%{config: config}|rest] = state.stack
      {old_version, new_version, config} = List.foldr config, {"","", []}, fn({key, value}, {old_version, new_version, config}) ->
        if key == :version do
          old_version = value
          {:modified, new_version} = modify_version({:modify, modification_functions}, old_version)
          value = new_version
        end
        {old_version, new_version, [{key, value}|config]}
      end
      stack = [%{root|config: config}|rest]
      {{old_version, new_version}, %{state| stack: stack}}
    end
    debug "Changed release version from #{old_version} to #{new_version}", options
  end

  defp print_version() do
    Mix.Shell.IO.info get_version
  end

  defp get_version() do
    Keyword.get(Mix.Project.config, :version)
  end

  defp update_version(old_version, :patch) do
    case String.split(old_version, ".") do
      [""] -> "0.0.1"
      [major] -> major <> ".0.1"
      [major, minor] -> major <> "." <> minor <> ".1"
      [major, minor, patch] ->
        patch = Regex.run(~r"^\d+", patch) |> List.first |> String.to_integer()
        major <> "." <> minor <> ".#{patch+1}"
    end
  end
  defp update_version(old_version, :minor) do
    case String.split(old_version, ".") do
      [""] -> "0.1.0"
      [major] -> major <> ".1.0"
      [major, minor|_] -> major <> "." <> "#{inspect String.to_integer(minor)+1}" <> ".0"
    end
  end
  defp update_version(old_version, :major) do
    case String.split(old_version, ".") do
      [""] -> "1.0.0"
      [major|_] -> "#{inspect String.to_integer(major)+1}" <> ".0.0"
    end
  end
  defp update_version(_old_version, version = <<_,_::binary>>) do
    version
  end

  defp debug(message, options) do
    if not quiet?(options) and verbose?(options) do
      Mix.Shell.IO.info message
    end
  end

  defp quiet?(options),   do: Keyword.get(options, :quiet, false)
  defp verbose?(options), do: Keyword.get(options, :verbose, false)


  @type modification_arg :: {modified_version::String.t, has_metadata::boolean}
  @type modification_fun :: ((modification_arg) -> modification_arg)

  @doc """
    Parses the arguments passed to this `release.version` task and merges them
    with the `AUTO_VERSION` environment variable. This arguments must not contain
    any output flags like `-V` or `-Q`.
  """
  @spec parse_args(OptionParser.argv) :: :show | {:error, message::String.t} | {:modify, [modification_fun]}
  def parse_args(args) do
    if args == [] && (default_args = System.get_env("AUTO_VERSION")) do
      default_args = args = OptionParser.split(default_args)
    else
      default_args = []
    end
    args = args |> List.foldr([], fn(arg, acc) ->
      if String.contains?(arg, "+") do
        String.split(arg, "+") ++ acc
      else
        [arg | acc]
      end
    end) |> Enum.filter(&(&1 != "increase" && &1 != "version"))
    args = args |> Enum.map(fn(arg) ->
      case arg do
        "append-" <> command -> command
        command -> command
      end
    end) |> Enum.map(fn(arg) ->
      case arg do
        "git-" <> command -> command
        "build-" <> command -> command
        command -> command
      end
    end) |> Enum.map(fn(arg) ->
      case arg do
        "commit-count" -> "commit_count"
        command -> command
      end
    end)
    {version_to_set, args} = get_version_to_set_from_args(args, [])
    known_options = ["major", "minor", "patch", "commit_count", "revision", "date", "branch", "set"]
    unknown_options = args -- known_options
    illegal_combinations = Enum.filter args, &(Enum.member?(["major", "minor", "patch", "set"], &1))
    cond do
      args == ["show"] -> :show
      unknown_options == ["count"] -> {:error, "Unknown option 'count'.\nDid you mean 'commit-count'?"}
      Enum.count(unknown_options) > 0 -> {:error, "Unknown options: #{Enum.join(unknown_options, " ")}"}
      args == [] -> :show
      Enum.count(illegal_combinations) > 1 -> {:error, "Illegal combination of options: #{Enum.join(illegal_combinations, " ")} can't be used together."}
      Enum.member?(args, "set") && (version_to_set == nil || Enum.member?(known_options, version_to_set)) -> {:error, "No version to set. Please add the version as argument after 'set' like: 'set 2.0.0-beta'."}
      Enum.any?(default_args, &(Enum.member?(illegal_combinations, &1))) ->  {:error, "Increasing major|minor|path or setting version is not allowed as default set in 'AUTO_VERSION' env."}
      true ->
        modification_functions = Enum.map args, fn(arg) ->
          case arg do
            "set" when version_to_set != nil -> &(modify_version_set(&1, version_to_set))
            _ -> String.to_atom("modify_version_" <> arg)
          end
        end
        {:modify, modification_functions}
    end
  end

  @doc """
    Gets the version which should be set as fixed version (instead of incrementing) from the args
    and returns the args without that value.
  """
  @spec get_version_to_set_from_args(args::OptionParser.argv, remaining_args::OptionParser.argv) :: {version_to_set::String.t|nil, args_without_version::OptionParser.argv}
  def get_version_to_set_from_args(_args = [], remaining_args), do: {_version = nil, Enum.reverse(remaining_args)}
  def get_version_to_set_from_args(_args = ["set", version | remaining], remaining_args), do: {version, Enum.reverse(remaining_args) ++ ["set"|remaining]}
  def get_version_to_set_from_args(_args = [other | remaining], remaining_args), do: get_version_to_set_from_args(remaining, [other|remaining_args])

  def modify_version_major({version, has_metadata}), do: {update_version(version, :major), has_metadata}
  def modify_version_minor({version, has_metadata}), do: {update_version(version, :minor), has_metadata}
  def modify_version_patch({version, has_metadata}), do: {update_version(version, :patch), has_metadata}
  def modify_version_commit_count({version, has_metadata}), do: {add_metadata(version, __MODULE__.get_commit_count, has_metadata), _has_metadata = true}
  def modify_version_revision({version, has_metadata}), do:     {add_metadata(version, __MODULE__.get_git_revision, has_metadata), _has_metadata = true}
  def modify_version_date({version, has_metadata}), do:         {add_metadata(version, __MODULE__.get_date, has_metadata),         _has_metadata = true}
  def modify_version_branch({version, has_metadata}), do:       {add_metadata(version, __MODULE__.get_branch, has_metadata),       _has_metadata = true}

  def modify_version_set({_version, has_metadata}, version_to_set), do: {version_to_set, has_metadata}


  defp add_metadata(version, metadata, _had_metadata = false), do: version <> "+" <> metadata
  defp add_metadata(version, metadata, _had_metadata = true),  do: version <> "-" <> metadata

  @doc """
    Modifies the current release version by applying the `modification_fun`s which
    were collected while parsing the args. If there was an error parsing the arguments
    passed to this task, this function prints the error and exists the erlang vm, meaning
    aborting the mix task. If `:show` is returned from parsing the arguments, this function
    just prints the current release version.
  """
  @spec modify_version({:modify, [modification_fun]} | {:error, message::String.t} | :show, version::String.t) :: :ok | :error | {:modified, new_version::String.t}
  def modify_version(:show, version) do
    IO.puts version
  end
  def modify_version({:error, message}, _version) do
    IO.puts :stderr, IO.ANSI.red <> "Error: " <> message <> IO.ANSI.reset
    :error
  end
  def modify_version({:modify, modification_functions}, version) do
    {version, _} = Enum.reduce modification_functions, {version, false},
      fn(modification_function, acc) when is_atom(modification_function) -> apply(__MODULE__, modification_function, [acc])
        (modification_function, acc) when is_function(modification_function, 1) -> apply(modification_function, [acc])
    end
    {:modified, version}
  end


  @doc """
    Gets the current revision of the git repository edeliver is used as deploy tool for.
    The sha1 hash containing 7 hexadecimal characters is returned.
  """
  @spec get_git_revision() :: String.t
  def get_git_revision() do
    System.cmd( "git", ["rev-parse", "--short", "HEAD"]) |> elem(0) |> String.rstrip
  end

  @doc "Gets the current number of commits across all branches"
  @spec get_commit_count() :: String.t
  def get_commit_count() do
    System.cmd( "git", ["rev-list", "--all", "--count"]) |> elem(0) |> String.rstrip
  end

  @doc "Gets the current branch that will be built"
  @spec get_branch() :: String.t
  def get_branch() do
    System.cmd( "git", ["rev-parse", "--abbrev-ref", "HEAD"]) |> elem(0) |> String.rstrip
  end

  @doc "Gets the current date in the form yyyymmdd"
  @spec get_date :: String.t
  def get_date() do
    {{year, month, day}, _time} = :calendar.local_time
    :io_lib.format('~4.10.0b~2.10.0b~2.10.0b', [year, month, day]) |> IO.iodata_to_binary
  end
end