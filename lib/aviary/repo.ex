defmodule Aviary.Repo do
  use Ecto.Repo,
    otp_app: :aviary,
    adapter: Ecto.Adapters.Postgres
end
