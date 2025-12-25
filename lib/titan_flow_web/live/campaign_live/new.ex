defmodule TitanFlowWeb.CampaignLive.New do
  use TitanFlowWeb, :live_view
  require Logger
  import Ecto.Query

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns
  alias TitanFlow.Templates
  alias TitanFlow.WhatsApp

  @default_mps 80

  @impl true
  def mount(_params, _session, socket) do
    templates = Templates.list_templates()
    phone_numbers = WhatsApp.list_phone_numbers()

    socket =
      socket
      |> assign(current_path: "/campaigns")
      |> assign(page_title: "New Campaign")
      # ALL templates for filtering
      |> assign(all_templates: templates)
      |> assign(phone_numbers: phone_numbers)
      # New sender config: list of %{phone_id: nil, template_ids: [], expanded: true}
      |> assign(
        senders_config: [%{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}]
      )
      |> assign(campaign_name: "")
      |> assign(dedup_window_days: 0)
      |> assign(saving: false)
      |> assign(error: nil)
      # Draft Mode state
      |> assign(draft_campaign: nil)
      # idle | uploading | importing | ready | error
      |> assign(import_status: "idle")
      |> assign(import_progress: 0)
      |> assign(import_count: 0)
      # Guard against double processing
      |> assign(upload_processed: false)
      |> allow_upload(:csv_file,
        accept: ~w(.csv .gz .zip),
        max_entries: 1,
        max_file_size: 100_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  # Progress callback - called automatically during upload
  defp handle_progress(:csv_file, entry, socket) do
    if entry.done? and not socket.assigns.upload_processed do
      # Upload complete - trigger processing
      Logger.info("CSV Upload complete, triggering processing")
      socket = maybe_process_completed_upload(socket)
      {:noreply, socket}
    else
      # Still uploading - just update progress
      {:noreply, assign(socket, import_progress: entry.progress)}
    end
  end

  # Extract phone selections from form params and update senders_config
  defp update_senders_from_params(socket, params) do
    Logger.debug("update_senders_from_params - all params keys: #{inspect(Map.keys(params))}")

    senders =
      Enum.map(socket.assigns.senders_config, fn sender ->
        # Look for "phone-{sender.id}" in params
        param_key = "phone-#{sender.id}"
        param_value = params[param_key]

        Logger.debug(
          "Checking sender #{sender.id}: param_key=#{param_key}, value=#{inspect(param_value)}, current phone_id=#{inspect(sender.phone_id)}"
        )

        mps_key = "mps-#{sender.id}"
        new_mps = parse_mps(params[mps_key], sender.mps || @default_mps)

        case param_value do
          nil ->
            %{sender | mps: new_mps}

          "" ->
            # Empty selection - reset phone_id
            if sender.phone_id != nil do
              Logger.info("Resetting phone_id to nil for sender #{sender.id}")
              %{sender | phone_id: nil, template_ids: [], mps: new_mps}
            else
              %{sender | mps: new_mps}
            end

          phone_id_str ->
            new_phone_id = String.to_integer(phone_id_str)

            if sender.phone_id != new_phone_id do
              Logger.info(
                "Updating phone_id from #{inspect(sender.phone_id)} to #{new_phone_id} for sender #{sender.id}"
              )

              # Phone changed - reset template selection
              %{sender | phone_id: new_phone_id, template_ids: [], mps: new_mps}
            else
              %{sender | mps: new_mps}
            end
        end
      end)

    assign(socket, senders_config: senders)
  end

  defp start_reimport(socket, campaign, dedup_days) do
    # Update campaign with new dedup setting first
    {:ok, updated_campaign} =
      Campaigns.update_campaign(campaign, %{dedup_window_days: dedup_days})

    parent = self()

    Task.start(fn ->
      try do
        Logger.info("Draft Mode: clearing contacts for re-import")
        # 1. Clear existing contacts
        {deleted, _} = Repo.delete_all(from c in "contacts", where: c.campaign_id == ^campaign.id)
        Logger.info("Draft Mode: deleted #{deleted} old contacts")

        # 2. Re-run import
        Logger.info("Draft Mode: restarting import with window #{dedup_days}")
        alias TitanFlow.Campaigns.Importer

        {:ok, inserted_count} =
          Importer.import_csv(updated_campaign.csv_path, updated_campaign.id)

        # 3. Reload stats
        final_campaign = Campaigns.get_campaign!(campaign.id)

        send(parent, {:import_complete, final_campaign, inserted_count})
      rescue
        e ->
          Logger.error("Re-import failed: #{inspect(e)}")
          send(parent, {:import_error, Exception.message(e)})
      end
    end)

    # Set status back to importing
    assign(socket, import_status: "importing", draft_campaign: updated_campaign)
  end

  # Detect completed uploads and trigger import
  defp maybe_process_completed_upload(socket) do
    uploads = socket.assigns.uploads.csv_file
    entries = uploads.entries

    # Find completed entries
    completed = Enum.filter(entries, fn entry -> entry.done? and not entry.cancelled? end)

    cond do
      # Already processed or importing
      socket.assigns.upload_processed ->
        # Just update progress if still uploading
        update_upload_progress(socket, entries)

      # Has completed uploads - process them
      Enum.any?(completed) ->
        Logger.info("Draft Mode: Upload complete, starting import")
        process_completed_upload(socket)

      # Still uploading - update progress  
      Enum.any?(entries) ->
        update_upload_progress(socket, entries)

      # No uploads
      true ->
        socket
    end
  end

  defp update_upload_progress(socket, entries) do
    case entries do
      [entry | _] ->
        # Show actual progress - if done, show 100%
        progress = if entry.done?, do: 100, else: entry.progress
        assign(socket, import_status: "uploading", import_progress: progress)

      [] ->
        socket
    end
  end

  defp process_completed_upload(socket) do
    Logger.info("Draft Mode: Processing completed upload")

    # Mark as processed to prevent double processing
    socket =
      assign(socket, upload_processed: true, import_status: "importing", import_progress: 100)

    # Consume uploaded entries (MUST be done synchronously in event handler)
    uploaded_files =
      consume_uploaded_entries(socket, :csv_file, fn %{path: path}, entry ->
        # Preserve original file extension for proper detection
        original_ext = Path.extname(entry.client_name) |> String.downcase()
        dest = Path.join(System.tmp_dir!(), "campaign_#{entry.uuid}#{original_ext}")
        File.cp!(path, dest)
        Logger.info("Draft Mode: File saved to #{dest} (original: #{entry.client_name})")
        {:ok, dest}
      end)

    csv_path = List.first(uploaded_files)

    if csv_path do
      # Create draft campaign
      campaign_name =
        if socket.assigns.campaign_name == "",
          do: "Draft Campaign",
          else: socket.assigns.campaign_name

      campaign_params = %{
        "name" => campaign_name,
        "csv_path" => csv_path,
        "status" => "draft",
        "dedup_window_days" => socket.assigns.dedup_window_days
      }

      case Campaigns.create_campaign(campaign_params) do
        {:ok, campaign} ->
          Logger.info("Draft Mode: Created draft campaign #{campaign.id}")

          # Start import in background task
          parent = self()

          Task.start(fn ->
            try do
              Logger.info("Draft Mode: Starting CSV import for campaign #{campaign.id}")
              alias TitanFlow.Campaigns.Importer
              {:ok, inserted_count} = Importer.import_csv(csv_path, campaign.id)

              # Reload campaign to get skip stats (updated inside Importer)
              updated_campaign = Campaigns.get_campaign!(campaign.id)
              skipped_count = updated_campaign.skipped_count || 0

              Logger.info(
                "Draft Mode: Import complete - #{inserted_count} inserted, #{skipped_count} duplicates skipped"
              )

              send(parent, {:import_complete, updated_campaign, inserted_count})
            rescue
              e ->
                Logger.error("Draft Mode: Import failed - #{Exception.message(e)}")
                Logger.error(Exception.format(:error, e, __STACKTRACE__))
                send(parent, {:import_error, Exception.message(e)})
            end
          end)

          assign(socket, draft_campaign: campaign, import_status: "importing")

        {:error, changeset} ->
          Logger.error("Draft Mode: Failed to create campaign - #{inspect(changeset.errors)}")

          assign(socket,
            import_status: "error",
            error: "Failed to create draft campaign",
            upload_processed: false
          )
      end
    else
      Logger.error("Draft Mode: No file path after consume")

      assign(socket,
        import_status: "error",
        error: "Failed to process uploaded file",
        upload_processed: false
      )
    end
  end

  # Handle import completion from background task
  @impl true
  def handle_info({:import_complete, campaign, count}, socket) do
    Logger.info("Draft Mode: Import complete - #{count} contacts ready")

    socket =
      socket
      |> assign(draft_campaign: campaign)
      |> assign(import_status: "ready")
      |> assign(import_count: count)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_error, error_msg}, socket) do
    Logger.error("Draft Mode: Import error - #{error_msg}")

    socket =
      socket
      |> assign(import_status: "error")
      |> assign(error: "Import failed: #{error_msg}")
      # Allow retry
      |> assign(upload_processed: false)

    {:noreply, socket}
  end

  # Handle form validation - also detect completed uploads and Dedup changes
  @impl true
  def handle_event("validate", params, socket) do
    campaign_params = params["campaign"] || %{}
    # Preserve existing name if not provided in this validate event
    name =
      case campaign_params["name"] do
        nil -> socket.assigns.campaign_name
        val -> val
      end

    # Check if dedup window changed
    new_dedup_val = parse_dedup_days(campaign_params["dedup_window_days"])
    old_dedup_val = socket.assigns.dedup_window_days
    dedup_changed = new_dedup_val != old_dedup_val

    # Handle phone selection from form params
    # Form fields are named "phone-{sender_id}" and contain the phone_id value
    socket = update_senders_from_params(socket, params)

    # Update socket with new values
    socket =
      socket
      |> assign(campaign_name: name)
      |> assign(dedup_window_days: new_dedup_val)
      # Clear error on validation
      |> assign(error: nil)

    # Check for completed uploads that haven't been processed yet
    socket = maybe_process_completed_upload(socket)

    # TRIGGER RE-IMPORT if dedup changed and we already have a draft campaign
    socket =
      if dedup_changed and socket.assigns.import_status == "ready" and
           socket.assigns.draft_campaign do
        Logger.info("Draft Mode: Dedup window changed to #{new_dedup_val}, re-importing...")

        # Debounce the re-import slightly to avoid rapid-fire reloads while typing
        # But for now, we'll just trigger it.
        start_reimport(socket, socket.assigns.draft_campaign, new_dedup_val)
      else
        socket
      end

    {:noreply, socket}
  end

  # Dedicated event handler for when file selection changes
  @impl true
  def handle_event("file-selected", _params, socket) do
    # Update status to uploading when file is selected
    socket =
      if Enum.any?(socket.assigns.uploads.csv_file.entries) do
        assign(socket, import_status: "uploading", import_progress: 0, upload_processed: false)
      else
        socket
      end

    {:noreply, socket}
  end

  # Sender Config Event Handlers

  @impl true
  def handle_event("add_sender", _params, socket) do
    new_sender = %{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}
    senders = socket.assigns.senders_config ++ [new_sender]
    {:noreply, assign(socket, senders_config: senders)}
  end

  @impl true
  def handle_event("remove_sender", %{"id" => sender_id}, socket) do
    senders = Enum.reject(socket.assigns.senders_config, &(&1.id == sender_id))
    # Ensure at least one sender
    senders =
      if senders == [],
        do: [%{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}],
        else: senders

    {:noreply, assign(socket, senders_config: senders)}
  end

  @impl true
  def handle_event("select_phone", params, socket) do
    sender_id = params["sender-id"]
    phone_id_str = params["phone-id"]
    phone_id = if phone_id_str in [nil, ""], do: nil, else: String.to_integer(phone_id_str)

    if phone_id && phone_selected_elsewhere?(socket.assigns.senders_config, sender_id, phone_id) do
      {:noreply, assign(socket, error: "That phone is already assigned to another sender")}
    else
      senders =
        Enum.map(socket.assigns.senders_config, fn sender ->
          if sender.id == sender_id do
            # Reset template selection when phone changes
            %{sender | phone_id: phone_id, template_ids: []}
          else
            sender
          end
        end)

      {:noreply, assign(socket, senders_config: senders, error: nil)}
    end
  end

  @impl true
  def handle_event(
        "toggle_sender_template",
        %{"sender-id" => sender_id, "template-id" => template_id},
        socket
      ) do
    template_id = String.to_integer(template_id)

    senders =
      Enum.map(socket.assigns.senders_config, fn sender ->
        if sender.id == sender_id do
          new_templates =
            if template_id in sender.template_ids do
              List.delete(sender.template_ids, template_id)
            else
              sender.template_ids ++ [template_id]
            end

          %{sender | template_ids: new_templates}
        else
          sender
        end
      end)

    {:noreply, assign(socket, senders_config: senders)}
  end

  # Legacy handlers (kept for backwards compatibility, now unused)
  @impl true
  def handle_event("toggle_template", %{"id" => _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_phone", %{"id" => _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", params, socket) do
    campaign_params = params["campaign"] || %{}
    name = campaign_params["name"] || socket.assigns.campaign_name
    socket = update_senders_from_params(socket, params)
    senders_config = socket.assigns.senders_config

    # Validation
    valid_senders =
      Enum.filter(senders_config, fn s ->
        s.phone_id != nil and length(s.template_ids) > 0
      end)

    duplicate_phones = duplicate_phone_ids(valid_senders)

    cond do
      String.trim(name) == "" ->
        {:noreply, assign(socket, error: "Campaign name is required")}

      duplicate_phones != [] ->
        {:noreply,
         assign(socket, error: "Duplicate phone selected: #{Enum.join(duplicate_phones, ", ")}")}

      Enum.empty?(valid_senders) ->
        {:noreply,
         assign(socket, error: "Please configure at least one sender with phone and templates")}

      socket.assigns.import_status != "ready" ->
        {:noreply, assign(socket, error: "Please wait for CSV import to complete")}

      true ->
        socket = assign(socket, saving: true, error: nil)
        do_start_draft_campaign(socket, name, valid_senders)
    end
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :csv_file, ref)}
  end

  defp do_start_draft_campaign(socket, name, senders_config) do
    alias TitanFlow.Campaigns.Orchestrator

    draft_campaign = socket.assigns.draft_campaign

    if draft_campaign do
      # Convert senders_config to storable format (already lists, just format)
      storable_config =
        Enum.map(senders_config, fn s ->
          %{
            "phone_id" => s.phone_id,
            "template_ids" => Enum.sort(s.template_ids),
            "mps" => s.mps || @default_mps
          }
        end)

      # Extract legacy fields for backwards compatibility
      phone_ids = Enum.map(senders_config, & &1.phone_id) |> Enum.uniq()
      all_template_ids = Enum.flat_map(senders_config, & &1.template_ids) |> Enum.uniq()
      [primary_template_id | fallback_ids] = all_template_ids
      fallback_template_id = List.first(fallback_ids)

      {:ok, campaign} =
        Campaigns.update_campaign(draft_campaign, %{
          name: name,
          senders_config: storable_config,
          # Legacy fields (backwards compat)
          primary_template_id: primary_template_id,
          fallback_template_id: fallback_template_id,
          phone_ids: phone_ids,
          template_ids: all_template_ids
        })

      # Start orchestration (CSV already imported)
      Task.start(fn ->
        Orchestrator.start_campaign(campaign, phone_ids, all_template_ids, nil)
      end)

      {:noreply,
       socket
       |> put_flash(:info, "Campaign '#{name}' started!")
       |> push_navigate(to: ~p"/campaigns")}
    else
      {:noreply, assign(socket, error: "Please upload a CSV file first", saving: false)}
    end
  end

  defp parse_dedup_days(nil), do: 0
  defp parse_dedup_days(""), do: 0

  defp parse_dedup_days(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_dedup_days(val) when is_integer(val), do: max(0, val)

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="New Campaign" />

    <div class="max-w-4xl mx-auto">
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5">
        
        <%= if @error do %>
          <div class="mb-5 p-4 bg-red-500/10 border border-red-500/30 rounded-lg text-red-400 text-sm">
            <%= @error %>
          </div>
        <% end %>

        <.form for={%{}} as={:campaign} phx-change="validate" phx-submit="save" class="space-y-6">
          <%!-- Campaign Name --%>
          <div>
            <label class="block text-sm font-medium text-zinc-300 mb-2">
              Campaign Name <span class="text-red-400">*</span>
            </label>
            <input
              type="text"
              name="campaign[name]"
              value={@campaign_name}
              class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500"
              placeholder="Enter campaign name"
              phx-debounce="300"
            />
          </div>

          <%!-- Deduplication Window --%>
          <div>
            <label class="block text-sm font-medium text-zinc-300 mb-2">
              Deduplication Window (days)
            </label>
            <input
              type="number"
              name="campaign[dedup_window_days]"
              value={@dedup_window_days}
              min="0"
              class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500"
              placeholder="0 = disabled"
              phx-debounce="300"
            />
            <p class="mt-1 text-xs text-zinc-500">
              Remove numbers already contacted within this many days. Enter 0 to disable.
            </p>
          </div>

          <%!-- CSV File Upload --%>
          <div>
            <label class="block text-sm font-medium text-zinc-300 mb-2">
              Contact List (CSV)
            </label>
            <div
              class="border-2 border-dashed border-zinc-700 rounded-lg p-6 text-center hover:border-indigo-500/50 transition-colors cursor-pointer"
              phx-drop-target={@uploads.csv_file.ref}
              onclick={"document.getElementById('#{@uploads.csv_file.ref}').click()"}
            >
              <.live_file_input upload={@uploads.csv_file} class="sr-only" phx-change="file-selected" />
              
              <%= for entry <- @uploads.csv_file.entries do %>
                <div class="flex items-center justify-between bg-indigo-500/10 border border-indigo-500/30 rounded-lg p-3 mb-2">
                  <span class="text-indigo-300 text-sm font-mono"><%= entry.client_name %></span>
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="text-red-400 hover:text-red-300"
                    onclick="event.stopPropagation();"
                  >
                    ✕
                  </button>
                </div>
                <div class="w-full bg-zinc-700 rounded-full h-1.5 mb-2">
                  <div class="bg-indigo-500 h-1.5 rounded-full transition-all" style={"width: #{entry.progress}%"}></div>
                </div>
                <%= for err <- upload_errors(@uploads.csv_file, entry) do %>
                  <p class="text-red-400 text-sm"><%= error_to_string(err) %></p>
                <% end %>
              <% end %>
              
              <%= if @uploads.csv_file.entries == [] do %>
                <div class="text-zinc-500">
                  <svg class="mx-auto h-10 w-10 mb-3 text-zinc-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                  </svg>
                  <p class="text-sm">Drop CSV, GZIP (.gz), or ZIP file here or <span class="text-indigo-400 font-medium">click to browse</span></p>
                  <p class="text-xs text-zinc-600 mt-1 font-mono">Format: phone, media_url, var1, var2... (compressed for faster upload)</p>
                </div>
              <% end %>
            </div>
            
            <%!-- Import Progress Status --%>
            <% 
              # Get current upload state from entries
              current_entry = List.first(@uploads.csv_file.entries)
              upload_progress = if current_entry, do: current_entry.progress, else: 0
              upload_done = current_entry && current_entry.done?
            %>
            <%= cond do %>
              <% @import_status == "ready" -> %>
                <div class="mt-4 p-3 rounded-lg border bg-emerald-500/10 border-emerald-500/30">
                  <div class="flex items-center gap-2">
                    <span class="text-emerald-400">✓</span>
                    <span class="text-sm text-emerald-400">
                      Ready! <span class="font-mono font-medium"><%= @import_count %></span> contacts imported
                    </span>
                  </div>
                </div>
                
                <%= if @draft_campaign && @draft_campaign.skipped_count > 0 do %>
                  <div class="mt-3 p-3 rounded-lg border bg-amber-500/10 border-amber-500/30">
                    <div class="flex items-center gap-2">
                      <span class="text-amber-400">⚠️</span>
                      <span class="text-sm font-medium text-amber-300">
                        <span class="font-mono font-bold"><%= @draft_campaign.skipped_count %></span> duplicate contacts removed
                      </span>
                    </div>
                    <div class="text-xs text-amber-400/80 ml-7 mt-1">
                      Already contacted within the last <%= @draft_campaign.dedup_window_days %> day<%= if @draft_campaign.dedup_window_days > 1, do: "s", else: "" %>
                    </div>
                  </div>
                <% end %>
              <% @import_status == "importing" -> %>
                <div class="mt-4 p-3 rounded-lg border bg-amber-500/10 border-amber-500/30">
                  <div class="flex items-center gap-2">
                    <div class="animate-spin h-4 w-4 border-2 border-amber-400 rounded-full border-t-transparent"></div>
                    <span class="text-sm text-amber-400">Importing contacts to database...</span>
                  </div>
                </div>
              <% @import_status == "error" -> %>
                <div class="mt-4 p-3 rounded-lg border bg-red-500/10 border-red-500/30">
                  <div class="flex items-center gap-2">
                    <span class="text-red-400">✕</span>
                    <span class="text-sm text-red-400">Import failed</span>
                  </div>
                </div>
              <% current_entry != nil -> %>
                <div class="mt-4 p-3 rounded-lg border bg-blue-500/10 border-blue-500/30">
                  <div class="flex items-center gap-2">
                    <%= if upload_done do %>
                      <div class="animate-spin h-4 w-4 border-2 border-blue-400 rounded-full border-t-transparent"></div>
                      <span class="text-sm text-blue-400">Processing upload...</span>
                    <% else %>
                      <div class="animate-spin h-4 w-4 border-2 border-blue-400 rounded-full border-t-transparent"></div>
                      <span class="text-sm text-blue-400">Uploading... <%= upload_progress %>%</span>
                    <% end %>
                  </div>
                </div>
              <% true -> %>
            <% end %>
          </div>

          <%!-- Sender Configuration --%>
          <div>
            <label class="block text-sm font-medium text-zinc-300 mb-2">
              Sender Configuration <span class="text-red-400">*</span>
            </label>
            <p class="text-xs text-zinc-500 mb-4">
              Configure which phone numbers send with which templates. Each phone will rotate through its assigned templates.
            </p>
            
            <%= if @phone_numbers == [] do %>
              <div class="p-4 bg-amber-500/10 border border-amber-500/30 rounded-lg text-amber-400 text-sm">
                No phone numbers configured. <.link navigate={~p"/numbers"} class="underline">Add phone numbers</.link> first.
              </div>
            <% else %>
              <div class="space-y-4">
                <%= for sender <- @senders_config do %>
                  <% available_templates = templates_for_phone(@all_templates, sender.phone_id, @phone_numbers) %>
                  <div class="p-4 rounded-lg border border-zinc-800 bg-zinc-900/50">
                    <div class="flex items-start gap-4">
                      <%!-- Phone Selector --%>
                      <div class="flex-1">
                        <label class="block text-xs text-zinc-500 mb-1">Phone Number</label>
                        <select 
                          id={"phone-select-#{sender.id}"}
                          class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50"
                          phx-hook="PhoneSelect"
                          data-sender-id={sender.id}
                        >
                          <option value="">Select phone...</option>
                          <%= for phone <- @phone_numbers do %>
                            <option value={phone.id} selected={sender.phone_id == phone.id}>
                              <%= phone.display_name || phone.mobile_number || phone.phone_number_id %>
                            </option>
                          <% end %>
                        </select>
                      </div>
                      
                      <%!-- MPS Required --%>
                      <div class="w-28">
                        <label class="block text-xs text-zinc-500 mb-1">MPS Required</label>
                        <input
                          type="number"
                          name={"mps-#{sender.id}"}
                          value={sender.mps || @default_mps}
                          min="10"
                          max="500"
                          phx-debounce="300"
                          class="w-full h-9 px-2 rounded-md text-xs bg-zinc-900 border border-zinc-800 text-zinc-100 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50"
                        />
                      </div>
                      
                      <%!-- Remove Button --%>
                      <%= if length(@senders_config) > 1 do %>
                        <button
                          type="button"
                          phx-click="remove_sender"
                          phx-value-id={sender.id}
                          class="mt-5 p-1.5 text-zinc-500 hover:text-red-400 hover:bg-red-500/10 rounded transition-colors"
                          title="Remove sender"
                        >
                          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                          </svg>
                        </button>
                      <% end %>
                    </div>
                    
                    <%!-- Templates for this phone --%>
                    <%= if sender.phone_id do %>
                      <div class="mt-3">
                        <label class="block text-xs text-zinc-500 mb-2">
                          Templates (<%= length(sender.template_ids) %> selected)
                        </label>
                        <%= if available_templates == [] do %>
                          <div class="text-xs text-amber-400 bg-amber-500/10 border border-amber-500/30 rounded p-2">
                            No approved templates for this phone. <.link navigate={~p"/templates"} class="underline">Sync templates</.link>.
                          </div>
                        <% else %>
                          <div class="flex flex-wrap gap-2">
                            <%= for template <- available_templates do %>
                              <button
                                type="button"
                                phx-click="toggle_sender_template"
                                phx-value-sender-id={sender.id}
                                phx-value-template-id={template.id}
                                class={"px-3 py-1.5 rounded-full text-xs font-medium border transition-colors " <>
                                  if template.id in sender.template_ids,
                                    do: "bg-indigo-500/20 border-indigo-500/50 text-indigo-300",
                                    else: "bg-zinc-800 border-zinc-700 text-zinc-400 hover:border-zinc-600"}
                              >
                                <%= template.name %>
                                <%= if template.id in sender.template_ids do %>
                                  <span class="ml-1">✓</span>
                                <% end %>
                              </button>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% else %>
                      <div class="mt-3 text-xs text-zinc-500 italic">
                        Select a phone to see available templates
                      </div>
                    <% end %>
                  </div>
                <% end %>
                
                <%!-- Add Sender Button --%>
                <button
                  type="button"
                  phx-click="add_sender"
                  class="w-full py-2.5 border-2 border-dashed border-zinc-700 rounded-lg text-sm text-zinc-500 hover:border-indigo-500/50 hover:text-indigo-400 transition-colors"
                >
                  + Add Another Sender
                </button>
              </div>
            <% end %>
          </div>

          <%!-- Submit Buttons --%>
          <div class="flex gap-3 pt-5 border-t border-zinc-800">
            <.link
              navigate={~p"/campaigns"}
              class="flex-1 h-9 px-4 border border-zinc-700 text-zinc-300 rounded-md text-center text-sm font-medium flex items-center justify-center hover:bg-zinc-800 transition-colors"
            >
              Cancel
            </.link>
            <button
              type="submit"
              disabled={@saving}
              class="flex-1 h-9 px-4 bg-indigo-600 hover:bg-indigo-500 disabled:bg-indigo-800 disabled:text-indigo-400 text-white rounded-md text-sm font-medium transition-colors"
            >
              <%= if @saving do %>
                <span class="flex items-center justify-center gap-2">
                  <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24">
                    <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"></circle>
                    <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
                  </svg>
                  Creating...
                </span>
              <% else %>
                Create Campaign
              <% end %>
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp parse_mps(nil, fallback), do: fallback
  defp parse_mps("", fallback), do: fallback
  defp parse_mps(val, _fallback) when is_integer(val), do: clamp_mps(val)

  defp parse_mps(val, fallback) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> clamp_mps(n)
      :error -> fallback
    end
  end

  defp clamp_mps(mps) when is_integer(mps) do
    mps
    |> max(10)
    |> min(500)
  end

  defp phone_selected_elsewhere?(senders_config, sender_id, phone_id) do
    Enum.any?(senders_config, fn sender ->
      sender.id != sender_id and sender.phone_id == phone_id
    end)
  end

  defp duplicate_phone_ids(senders_config) do
    senders_config
    |> Enum.map(& &1.phone_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1)
    |> Enum.filter(fn {_phone_id, list} -> length(list) > 1 end)
    |> Enum.map(fn {phone_id, _} -> to_string(phone_id) end)
  end

  defp error_to_string(:too_large), do: "File too large (max 100MB)"
  defp error_to_string(:not_accepted), do: "Only CSV files are accepted"
  defp error_to_string(:too_many_files), do: "Only one file allowed"
  defp error_to_string(err), do: "Upload error: #{inspect(err)}"

  # Generate unique ID for sender config items
  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Filter templates by phone's phone_number_id (templates belong to specific phones)
  defp templates_for_phone(all_templates, phone_id, phone_numbers) do
    phone = Enum.find(phone_numbers, &(&1.id == phone_id))

    if phone do
      Enum.filter(all_templates, fn t ->
        t.phone_number_id == phone.id and
          t.status == "APPROVED" and
          t.category == "UTILITY"
      end)
    else
      []
    end
  end
end
