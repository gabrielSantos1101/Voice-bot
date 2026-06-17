defmodule ArcaneVoice.DiscordBot.CommandHandler do
  @command_map %{
    "get" => ArcaneVoice.DiscordBot.Commands.Get,
    "set" => ArcaneVoice.DiscordBot.Commands.Set,
    "del" => ArcaneVoice.DiscordBot.Commands.Del,
    "apikey" => ArcaneVoice.DiscordBot.Commands.ApiKey,
    "kv" => ArcaneVoice.DiscordBot.Commands.KV,
    "help" => ArcaneVoice.DiscordBot.Commands.KV
  }

  def handle_message(payload) do
    case payload.data do
      # Don't handle messages from other bots
      %{"author" => %{"bot" => true}} ->
        :ok

      %{"content" => content} ->
        if String.starts_with?(content, Application.get_env(:arcane_voice, :command_prefix)) do
          [attempted_command | args] =
            content
            |> String.to_charlist()
            |> tl()
            |> to_string()
            |> String.split(" ")

          unless @command_map[attempted_command] == nil do
            @command_map[attempted_command].handle(args, payload.data)
          end
        end

      _ ->
        :ok
    end
  end

  def handle_command(_unknown_command, _args), do: :ok
end
