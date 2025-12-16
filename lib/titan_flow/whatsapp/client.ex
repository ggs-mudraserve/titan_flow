defmodule TitanFlow.WhatsApp.Client do
  @moduledoc """
  WhatsApp Cloud API client for sending messages.

  Provides functions for sending template messages via the Meta Graph API.
  Returns HTTP headers alongside response body for rate limit tracking.
  """

  @graph_api_base "https://graph.facebook.com/v21.0"

  @doc """
  Send a template message via WhatsApp Cloud API.

  ## Parameters
  - `to_phone` - Recipient phone number in international format (e.g., "14155551234")
  - `template_name` - Name of the approved template
  - `language_code` - Language code (e.g., "en_US", "es")
  - `components` - List of template components (header, body, button parameters)
  - `credentials` - Map with `:access_token` and `:phone_number_id`

  ## Returns
  - `{:ok, response_body, headers}` - Success with response body and HTTP headers
  - `{:error, reason}` - On failure

  ## Example
      iex> credentials = %{access_token: "token", phone_number_id: "123456789"}
      iex> components = [
      ...>   %{"type" => "body", "parameters" => [%{"type" => "text", "text" => "John"}]}
      ...> ]
      iex> Client.send_template("14155551234", "hello_world", "en_US", components, credentials)
      {:ok, %{"messages" => [%{"id" => "wamid.xxx"}]}, [{"x-rate-limit-remaining", "999"}]}
  """
  @spec send_template(String.t(), String.t(), String.t(), list(), map()) ::
          {:ok, map(), list()} | {:error, term()}
  def send_template(to_phone, template_name, language_code, components, credentials) do
    %{access_token: access_token, phone_number_id: phone_number_id} = credentials

    url = "#{@graph_api_base}/#{phone_number_id}/messages"

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to_phone,
      type: "template",
      template: %{
        name: template_name,
        language: %{
          code: language_code
        },
        components: components
      }
    }

    case Req.post(url,
           json: payload,
           headers: [
             {"Authorization", "Bearer #{access_token}"},
             {"Content-Type", "application/json"}
           ]
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, body, headers}

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:error, {:api_error, status, body, headers}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Extract rate limit information from response headers.

  ## Parameters
  - `headers` - List of header tuples from API response

  ## Returns
  - Map with rate limit info: `%{remaining: integer, limit: integer, reset: integer}`
  """
  @spec parse_rate_limit_headers(list()) :: map()
  def parse_rate_limit_headers(headers) do
    headers_map =
      headers
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        # Handle both single values and lists
        val = if is_list(value), do: List.first(value), else: value
        Map.put(acc, String.downcase(key), val)
      end)

    %{
      remaining: parse_int(Map.get(headers_map, "x-rate-limit-remaining")),
      limit: parse_int(Map.get(headers_map, "x-rate-limit-limit")),
      reset: parse_int(Map.get(headers_map, "x-rate-limit-reset"))
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end
  defp parse_int(value) when is_integer(value), do: value

  @doc """
  Send a text message via WhatsApp Cloud API.

  ## Parameters
  - `phone_number_id` - The sender's phone number ID
  - `to_phone` - Recipient phone number in international format
  - `text` - Message text content
  - `access_token` - Meta API access token

  ## Returns
  - `{:ok, response_body}` - Success with response body
  - `{:error, reason}` - On failure
  """
  @spec send_text(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def send_text(phone_number_id, to_phone, text, access_token) do
    url = "#{@graph_api_base}/#{phone_number_id}/messages"

    payload = %{
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: to_phone,
      type: "text",
      text: %{
        preview_url: false,
        body: text
      }
    }

    case Req.post(url,
           json: payload,
           headers: [
             {"Authorization", "Bearer #{access_token}"},
             {"Content-Type", "application/json"}
           ]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
