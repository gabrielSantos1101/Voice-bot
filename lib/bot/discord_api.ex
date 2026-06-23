defmodule ArcaneVoice.DiscordBot.DiscordApi do
  require Logger

  @api_host "https://discord.com/api/v10"

  def register_guild_commands(application_id, guild_id) do
    # Remove any stale global commands first to avoid duplicates
    delete_global_commands(application_id)

    url = "#{@api_host}/applications/#{application_id}/guilds/#{guild_id}/commands"

    body = [
      %{
        "name" => "tts",
        "description" => "Speak text in your current voice channel",
        "type" => 1,
        "options" => [
          %{
            "name" => "text",
            "description" => "The text to speak",
            "type" => 3,
            "required" => true
          }
        ]
      },
      %{
        "name" => "settings",
        "description" => "Configure voice and voice-channel behavior",
        "type" => 1
      },
      %{
        "name" => "join",
        "description" => "Have your text messages read aloud in the voice channel",
        "type" => 1
      },
      %{
        "name" => "leave",
        "description" => "Stop having your text messages read aloud",
        "type" => 1
      }
    ]

    case :put
         |> Finch.build(url, headers(), Jason.encode!(body))
         |> Finch.request(ArcaneVoice.Finch) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Guild slash commands registered (status #{status})")

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Guild command registration failed (status #{status}): #{body}")

      {:error, reason} ->
        Logger.error("Guild command registration error: #{inspect(reason)}")
    end
  end

  defp delete_global_commands(application_id) do
    url = "#{@api_host}/applications/#{application_id}/commands"

    case :put
         |> Finch.build(url, headers(), Jason.encode!([]))
         |> Finch.request(ArcaneVoice.Finch) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Global commands cleared (status #{status})")

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Global command cleanup failed (status #{status}): #{body}")

      {:error, reason} ->
        Logger.error("Global command cleanup error: #{inspect(reason)}")
    end
  end

  def send_message(channel_id, content) when is_binary(content) do
    ArcaneVoice.Metrics.Collector.inc(:counter, :arcane_voice_discord_messages_sent)

    sanitized_content =
      content
      |> String.replace("@", "@​\u200b")

    :post
    |> Finch.build(
      "#{@api_host}/channels/#{channel_id}/messages",
      headers(),
      Jason.encode!(%{content: sanitized_content})
    )
    |> Finch.request(ArcaneVoice.Finch)
  end

  def send_message(channel_id, %{} = embed) do
    ArcaneVoice.Metrics.Collector.inc(:counter, :arcane_voice_discord_messages_sent)

    :post
    |> Finch.build(
      "#{@api_host}/channels/#{channel_id}/messages",
      headers(),
      Jason.encode!(%{embeds: [embed]})
    )
    |> Finch.request(ArcaneVoice.Finch)
  end

  def create_dm(recipient) do
    {:ok, response} =
      :post
      |> Finch.build(
        "#{@api_host}/users/@me/channels",
        headers(),
        Jason.encode!(%{recipient_id: recipient})
      )
      |> Finch.request(ArcaneVoice.Finch)

    case Jason.decode!(response.body) do
      %{"id" => id} ->
        id

      _ ->
        :ok
    end
  end

  def get_user_voice_state(guild_id, user_id) do
    url = "#{@api_host}/guilds/#{guild_id}/voice-states/#{user_id}"

    case :get
         |> Finch.build(url, headers())
         |> Finch.request(ArcaneVoice.Finch) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          _ -> {:error, :parse_failed}
        end

      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 404}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("get_user_voice_state: status #{status}: #{body}")
        {:error, status}

      {:error, reason} ->
        Logger.error("get_user_voice_state: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp headers do
    [
      {"Authorization", "Bot " <> Application.get_env(:arcane_voice, :bot_token)},
      {"Content-Type", "application/json"}
    ]
  end
end
