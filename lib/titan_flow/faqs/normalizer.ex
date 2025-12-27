defmodule TitanFlow.Faqs.Normalizer do
  @moduledoc false

  @short_messages MapSet.new(["hi", "hello", "hey", "ok", "okay", "yes"])

  def normalize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]+/i, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def normalize(_), do: ""

  def short_message?(normalized) when is_binary(normalized) do
    MapSet.member?(@short_messages, normalized)
  end

  def short_message?(_), do: false
end
