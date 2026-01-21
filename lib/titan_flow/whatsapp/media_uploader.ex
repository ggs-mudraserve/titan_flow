defmodule TitanFlow.WhatsApp.MediaUploader do
  @moduledoc """
  Handles WhatsApp Cloud API media uploads.

  Provides two upload methods:
  - `upload_for_template/5` - Resumable upload for template media (returns session handle)
  - `upload_for_sending/3` - Direct upload for sending messages (returns media ID)
  """

  @graph_api_base "https://graph.facebook.com/v21.0"
  @http1_connect_opts [protocols: [:http1]]
  alias TitanFlow.Http

  @doc """
  Upload media for use in WhatsApp templates.

  Uses the resumable upload protocol:
  1. Create upload session with file metadata
  2. Upload file binary to the session
  3. Return the session handle (used for template creation)

  ## Parameters
  - `file_path` - Path to the file on disk
  - `file_size` - Size of the file in bytes
  - `mime_type` - MIME type of the file (e.g., "image/png", "video/mp4")
  - `app_id` - Facebook App ID
  - `access_token` - WhatsApp Business API access token

  ## Returns
  - `{:ok, session_handle}` on success
  - `{:error, reason}` on failure
  """
  @spec upload_for_template(String.t(), integer(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_for_template(file_path, file_size, mime_type, app_id, access_token) do
    with {:ok, session_id} <- create_upload_session(file_size, mime_type, app_id, access_token),
         {:ok, handle} <- upload_file_to_session(file_path, session_id, access_token) do
      {:ok, handle}
    end
  end

  @doc """
  Upload media for sending in WhatsApp messages.

  Uses multipart form upload directly to the phone number's media endpoint.

  ## Parameters
  - `file_path` - Path to the file on disk
  - `phone_number_id` - WhatsApp Phone Number ID
  - `access_token` - WhatsApp Business API access token

  ## Returns
  - `{:ok, media_id}` on success
  - `{:error, reason}` on failure
  """
  @spec upload_for_sending(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def upload_for_sending(file_path, phone_number_id, access_token) do
    url = "#{@graph_api_base}/#{phone_number_id}/media"

    file_name = Path.basename(file_path)
    mime_type = get_mime_type(file_path)

    with {:ok, file_binary} <- File.read(file_path) do
      multipart =
        {:multipart,
         [
           {:file, file_binary, {"form-data", [{"name", "file"}, {"filename", file_name}]},
            [{"content-type", mime_type}]},
           {"messaging_product", "whatsapp"},
           {"type", get_media_type(mime_type)}
         ]}

      case Http.post(url,
             body: multipart,
             connect_options: @http1_connect_opts,
             headers: [
               {"Authorization", "Bearer #{access_token}"}
             ]
           ) do
        {:ok, %Req.Response{status: 200, body: %{"id" => media_id}}} ->
          {:ok, media_id}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  # Private Functions

  defp create_upload_session(file_size, mime_type, app_id, access_token) do
    url = "#{@graph_api_base}/#{app_id}/uploads"

    case Http.post(url,
           headers: [
             {"Authorization", "OAuth #{access_token}"}
           ],
           connect_options: @http1_connect_opts,
           params: [
             file_length: file_size,
             file_type: mime_type
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"id" => session_id}}} ->
        {:ok, session_id}

      # Handle case where body is a JSON string (not decoded)
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"id" => session_id}} -> {:ok, session_id}
          _ -> {:error, {:session_create_failed, 200, body}}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:session_create_failed, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp upload_file_to_session(file_path, session_id, access_token) do
    url = "#{@graph_api_base}/#{session_id}"

    with {:ok, file_binary} <- File.read(file_path) do
      case Http.post(url,
             body: file_binary,
             headers: [
               {"Authorization", "OAuth #{access_token}"},
               {"file_offset", "0"}
             ],
             connect_options: @http1_connect_opts
           ) do
        {:ok, %Req.Response{status: 200, body: %{"h" => handle}}} ->
          {:ok, handle}

        # Handle case where body is a JSON string (not decoded)
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, %{"h" => handle}} -> {:ok, handle}
            _ -> {:error, {:upload_failed, 200, body}}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:upload_failed, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  defp get_mime_type(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      ".mp4" -> "video/mp4"
      ".3gp" -> "video/3gpp"
      ".pdf" -> "application/pdf"
      ".mp3" -> "audio/mpeg"
      ".ogg" -> "audio/ogg"
      ".amr" -> "audio/amr"
      ".aac" -> "audio/aac"
      _ -> "application/octet-stream"
    end
  end

  defp get_media_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      String.starts_with?(mime_type, "audio/") -> "audio"
      mime_type == "application/pdf" -> "document"
      true -> "document"
    end
  end
end
