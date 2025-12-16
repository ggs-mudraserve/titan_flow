defmodule TitanFlow.Campaigns.RedisProducer do
  @moduledoc """
  Custom Broadway producer for Redis lists using Redix.

  Polls a Redis list for items and converts them to Broadway messages.
  Uses LPOP to remove items from the queue.
  """

  use GenStage

  @poll_interval_ms 10

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    redis_config = Keyword.fetch!(opts, :redis_config)
    list_name = Keyword.fetch!(opts, :list_name)
    batch_size = Keyword.get(opts, :batch_size, 100)

    {:ok, conn} = Redix.start_link(
      host: redis_config[:host],
      port: redis_config[:port],
      password: redis_config[:password]
    )

    state = %{
      conn: conn,
      list_name: list_name,
      batch_size: batch_size,
      demand: 0
    }

    {:producer, state}
  end

  @impl true
  def handle_demand(incoming_demand, state) do
    new_demand = state.demand + incoming_demand
    {messages, new_state} = fetch_messages(%{state | demand: new_demand})
    {:noreply, messages, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    {messages, new_state} = fetch_messages(state)
    {:noreply, messages, new_state}
  end

  defp fetch_messages(%{demand: 0} = state) do
    {[], state}
  end

  defp fetch_messages(state) do
    # Fetch up to demand items, but cap at batch_size per poll
    count = min(state.demand, state.batch_size)

    # Use LPOP with count (Redis 6.2+) or multiple LPOPs
    case Redix.command(state.conn, ["LPOP", state.list_name, count]) do
      {:ok, nil} ->
        # Queue empty, schedule next poll
        Process.send_after(self(), :poll, @poll_interval_ms)
        {[], state}

      {:ok, items} when is_list(items) ->
        messages = Enum.map(items, &wrap_message/1)
        new_demand = state.demand - length(messages)
        
        # If we got items and still have demand, continue immediately
        if new_demand > 0 do
          send(self(), :poll)
        end
        
        {messages, %{state | demand: new_demand}}

      {:ok, item} when is_binary(item) ->
        # Single item returned (older Redis)
        messages = [wrap_message(item)]
        new_demand = state.demand - 1
        
        if new_demand > 0 do
          send(self(), :poll)
        end
        
        {messages, %{state | demand: new_demand}}

      {:error, reason} ->
        require Logger
        Logger.error("Redis LPOP failed: #{inspect(reason)}")
        Process.send_after(self(), :poll, @poll_interval_ms * 2)
        {[], state}
    end
  end

  defp wrap_message(data) do
    %Broadway.Message{
      data: data,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  # Broadway acknowledger callback (no-op since LPOP already removed)
  def ack(_ack_ref, _successful, _failed) do
    :ok
  end
end
