defmodule ArcaneVoice.DiscordBot.DiscordApi do
  require Logger

  @api_host "https://discord.com/api/v10"

  def register_commands(application_id) do
    url = "#{@api_host}/applications/#{application_id}/commands"

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
      }
    ]

    case :put
         |> Finch.build(url, headers(), Jason.encode!(body))
         |> Finch.request(ArcaneVoice.Finch) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Slash commands registered (status #{status})")

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Command registration failed (status #{status}): #{body}")

      {:error, reason} ->
        Logger.error("Command registration error: #{inspect(reason)}")
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

  defp headers do
    [
      {"Authorization", "Bot " <> Application.get_env(:arcane_voice, :bot_token)},
      {"Content-Type", "application/json"}
    ]
  end
end
