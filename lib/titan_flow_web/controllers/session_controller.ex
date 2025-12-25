defmodule TitanFlowWeb.SessionController do
  use TitanFlowWeb, :controller

  require Logger

  @login_rate_window_ms 60_000
  @login_rate_limit 5

  def create(conn, %{"pin" => pin}) do
    case check_rate_limit(conn) do
      :allow ->
        expected_pin = Application.get_env(:titan_flow, :admin_pin, "123456")

        if valid_pin?(pin, expected_pin) do
          conn
          |> configure_session(renew: true)
          |> put_session(:user_authenticated, true)
          |> put_flash(:info, "Welcome back!")
          |> redirect(to: "/")
        else
          invalid_pin(conn)
        end

      :deny ->
        rate_limited(conn)
    end
  end

  def create(conn, _params) do
    case check_rate_limit(conn) do
      :allow -> invalid_pin(conn)
      :deny -> rate_limited(conn)
    end
  end

  defp invalid_pin(conn) do
    conn
    |> configure_session(renew: true)
    |> put_flash(:error, "Incorrect PIN")
    |> redirect(to: "/login")
  end

  defp rate_limited(conn) do
    retry_after = div(@login_rate_window_ms, 1000)

    conn
    |> configure_session(renew: true)
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_flash(:error, "Too many attempts. Please try again in a minute.")
    |> redirect(to: "/login")
  end

  defp check_rate_limit(conn) do
    key = "login:" <> client_ip(conn)

    case Hammer.check_rate(key, @login_rate_window_ms, @login_rate_limit) do
      {:allow, _count} ->
        :allow

      {:deny, _limit} ->
        :deny

      {:error, reason} ->
        Logger.warning("Login rate limit skipped: #{inspect(reason)}")
        :allow
    end
  end

  defp client_ip(conn) do
    forwarded = get_req_header(conn, "x-forwarded-for") |> List.first()

    cond do
      is_binary(forwarded) and forwarded != "" ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      is_binary(real_ip = get_req_header(conn, "x-real-ip") |> List.first()) ->
        String.trim(real_ip)

      true ->
        ip_to_string(conn.remote_ip) || "unknown"
    end
  end

  defp ip_to_string({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_to_string({_, _, _, _, _, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp ip_to_string(_), do: nil

  defp valid_pin?(pin, expected_pin)
       when is_binary(pin) and is_binary(expected_pin) and
              byte_size(pin) == byte_size(expected_pin) do
    Plug.Crypto.secure_compare(pin, expected_pin)
  end

  defp valid_pin?(_, _), do: false
end
