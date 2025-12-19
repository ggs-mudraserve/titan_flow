defmodule TitanFlow.Templates.TemplateCache do
  @moduledoc """
  Global ETS cache for template data (Phase 2: 4A).
  
  ## Purpose
  
  Eliminates database queries for template lookups during campaign execution.
  Templates are loaded at startup and refreshed periodically.
  
  ## Cache Structure
  
  ETS table `:template_cache` with entries:
  - Key: `{:by_id, template_id}` => template struct
  - Key: `{:by_name, template_name}` => template struct
  - Key: `{:by_phone, phone_number_id}` => [template structs]
  
  ## Usage
  
      # Get template by ID (O(1))
      TemplateCache.get(123)
      
      # Get template by name (O(1))
      TemplateCache.get_by_name("my_template")
      
      # Get all templates for a phone (O(1))
      TemplateCache.get_by_phone(phone_number_id)
      
      # Force refresh (e.g., after Meta sync)
      TemplateCache.refresh()
  """
  
  use GenServer
  require Logger
  
  alias TitanFlow.Templates
  alias TitanFlow.Templates.Template
  
  @table_name :template_cache
  @refresh_interval_ms 5 * 60 * 1000  # 5 minutes
  
  # Public API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Get template by ID from cache.
  Returns `{:ok, template}` or `{:error, :not_found}`.
  """
  def get(template_id) when is_integer(template_id) do
    case :ets.lookup(@table_name, {:by_id, template_id}) do
      [{_, template}] -> {:ok, template}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :cache_not_ready}
  end
  
  @doc """
  Get template by name from cache.
  Returns `{:ok, template}` or `{:error, :not_found}`.
  """
  def get_by_name(template_name) when is_binary(template_name) do
    case :ets.lookup(@table_name, {:by_name, template_name}) do
      [{_, template}] -> {:ok, template}
      [] -> {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :cache_not_ready}
  end
  
  @doc """
  Get all templates for a phone number from cache.
  Returns list of templates (may be empty).
  """
  def get_by_phone(phone_number_id) when is_integer(phone_number_id) do
    case :ets.lookup(@table_name, {:by_phone, phone_number_id}) do
      [{_, templates}] -> templates
      [] -> []
    end
  rescue
    ArgumentError -> []
  end
  
  @doc """
  Get all approved templates for a phone number.
  """
  def get_approved_by_phone(phone_number_id) do
    phone_number_id
    |> get_by_phone()
    |> Enum.filter(&(&1.status == "APPROVED"))
  end
  
  @doc """
  Force refresh the cache from database.
  """
  def refresh do
    GenServer.call(__MODULE__, :refresh, 30_000)
  end
  
  @doc """
  Invalidate a specific template (e.g., from webhook).
  The template will be refetched from DB on next refresh.
  """
  def invalidate(template_id) when is_integer(template_id) do
    GenServer.cast(__MODULE__, {:invalidate, template_id})
  end
  
  @doc """
  Get cache stats for monitoring.
  """
  def stats do
    case :ets.info(@table_name) do
      :undefined -> %{size: 0, memory: 0, status: :not_ready}
      info ->
        %{
          size: Keyword.get(info, :size, 0),
          memory: Keyword.get(info, :memory, 0),
          status: :ready
        }
    end
  end
  
  # GenServer Callbacks
  
  @impl true
  def init(_opts) do
    # Create ETS table owned by this process
    :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    
    Logger.info("TemplateCache: Starting, loading templates...")
    
    # Load templates synchronously on startup
    load_all_templates()
    
    # Schedule periodic refresh
    schedule_refresh()
    
    {:ok, %{last_refresh: System.monotonic_time(:second)}}
  end
  
  @impl true
  def handle_call(:refresh, _from, state) do
    count = load_all_templates()
    {:reply, {:ok, count}, %{state | last_refresh: System.monotonic_time(:second)}}
  end
  
  @impl true
  def handle_cast({:invalidate, template_id}, state) do
    # Remove the invalidated template from cache
    :ets.delete(@table_name, {:by_id, template_id})
    Logger.debug("TemplateCache: Invalidated template #{template_id}")
    {:noreply, state}
  end
  
  @impl true
  def handle_info(:refresh, state) do
    load_all_templates()
    schedule_refresh()
    {:noreply, %{state | last_refresh: System.monotonic_time(:second)}}
  end
  
  # Private Functions
  
  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end
  
  defp load_all_templates do
    templates = Templates.list_templates()
    
    # Clear existing entries
    :ets.delete_all_objects(@table_name)
    
    # Index by ID
    Enum.each(templates, fn template ->
      :ets.insert(@table_name, {{:by_id, template.id}, template})
    end)
    
    # Index by name
    Enum.each(templates, fn template ->
      :ets.insert(@table_name, {{:by_name, template.name}, template})
    end)
    
    # Index by phone_number_id
    templates
    |> Enum.filter(& &1.phone_number_id)
    |> Enum.group_by(& &1.phone_number_id)
    |> Enum.each(fn {phone_id, phone_templates} ->
      :ets.insert(@table_name, {{:by_phone, phone_id}, phone_templates})
    end)
    
    count = length(templates)
    Logger.info("TemplateCache: Loaded #{count} templates into cache")
    count
  end
end
