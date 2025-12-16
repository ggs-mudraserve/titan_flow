defmodule TitanFlow.Repo do
  use Ecto.Repo,
    otp_app: :titan_flow,
    adapter: Ecto.Adapters.Postgres
end
