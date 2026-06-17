defmodule ArcaneVoice.DiscordBot.DiscordApi do
  @api_host "https://discord.com/api/v9"

  def send_message(channel_id, content) when is_binary(content) do
    ArcaneVoice.Metrics.Collector.inc(:counter, :arcane_voice_discord_messages_sent)

    sanitized_content =
      content
      |> String.replace("@", "@​\u200b")

    :post
    |> Finch.build(
      "#{@api_host}/channels/#{channel_id}/messages",
      [
        {"Authorization", "Bot " <> Application.get_env(:arcane_voice, :bot_token)},
        {"Content-Type", "application/json"}
      ],
      Jason.encode!(%{content: sanitized_content})
    )
    |> Finch.request(ArcaneVoice.Finch)
  end

  def send_message(channel_id, %{} = embed) do
    ArcaneVoice.Metrics.Collector.inc(:counter, :arcane_voice_discord_messages_sent)

    :post
    |> Finch.build(
      "#{@api_host}/channels/#{channel_id}/messages",
      [
        {"Authorization", "Bot " <> Application.get_env(:arcane_voice, :bot_token)},
        {"Content-Type", "application/json"}
      ],
      Jason.encode!(%{embeds: [embed]})
    )
    |> Finch.request(ArcaneVoice.Finch)
  end

  def create_dm(recipient) do
    {:ok, response} =
      :post
      |> Finch.build(
        "#{@api_host}/users/@me/channels",
        [
          {"Authorization", "Bot " <> Application.get_env(:arcane_voice, :bot_token)},
          {"Content-Type", "application/json"}
        ],
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
end
