defmodule TitanFlow.Http do
  @moduledoc false

  def get(url, opts \\ []) do
    Req.get(url, with_ssl_opts(opts))
  end

  def post(url, opts \\ []) do
    Req.post(url, with_ssl_opts(opts))
  end

  defp with_ssl_opts(opts) do
    if Keyword.has_key?(opts, :finch) do
      opts
    else
      transport_opts = [cacertfile: ca_certfile()]

      connect_options =
        case Keyword.get(opts, :connect_options) do
          nil ->
            [transport_opts: transport_opts]

          existing ->
            Keyword.update(existing, :transport_opts, transport_opts, fn existing_transport ->
              Keyword.merge(transport_opts, existing_transport)
            end)
        end

      Keyword.put(opts, :connect_options, connect_options)
    end
  end

  defp ca_certfile do
    System.get_env("SSL_CERT_FILE") || "/etc/ssl/certs/ca-certificates.crt"
  end
end
