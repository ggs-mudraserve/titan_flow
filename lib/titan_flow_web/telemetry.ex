defmodule TitanFlowWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("titan_flow.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("titan_flow.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("titan_flow.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("titan_flow.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("titan_flow.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Campaign System Metrics (Phase 1: 5A)
      summary("titan_flow.campaign.pipeline.message_processed.duration",
        tags: [:campaign_id, :phone_number_id, :status],
        unit: {:native, :millisecond},
        description: "Time to process a single message in Pipeline"
      ),
      summary("titan_flow.campaign.buffer.refill.duration",
        tags: [:campaign_id, :phone_number_id],
        unit: {:native, :millisecond},
        description: "Time to refill BufferManager from database"
      ),
      sum("titan_flow.campaign.buffer.refill.count",
        tags: [:campaign_id, :phone_number_id],
        description: "Number of contacts fetched per refill"
      ),
      summary("titan_flow.campaign.log_batcher.flush.duration",
        tags: [:buffer_type],
        unit: {:native, :millisecond},
        description: "Time to flush log batch to database"
      ),
      last_value("titan_flow.campaign.queue.depth.depth",
        tags: [:campaign_id, :phone_number_id],
        description: "Current queue depth per phone"
      ),
      counter("titan_flow.campaign.pool.saturation.checkout_time_ms",
        description: "Pool saturation alert counter"
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {TitanFlowWeb, :count_users, []}
    ]
  end
end
