defmodule TitanFlowWeb.TemplateLive.Index do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Templates
  alias TitanFlow.WhatsApp
  alias TitanFlow.WhatsApp.MediaUploader
  alias TitanFlowWeb.DateTimeHelpers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/templates")
      |> assign(page_title: "Templates")
      |> assign(syncing: false)
      |> assign(show_clone_modal: false)
      |> assign(cloning_template: nil)
      |> assign(show_preview_modal: false)
      |> assign(preview_template: nil)
      |> assign(show_delete_modal: false)
      |> assign(deleting_template: nil)
      |> assign(clone_name: "")
      |> assign(clone_body_text: "")
      |> assign(clone_language: "en_US")
      |> assign(uploaded_file: nil)
      |> assign(media_handle: nil)
      |> assign(media_type: nil)
      |> assign(header_type: "none")
      |> assign(uploading: false)
      |> assign(upload_error: nil)
      # Filters for table view
      |> assign(filter_category: "all")
      |> assign(filter_status: "all")
      |> assign(filter_search: "")
      |> assign(filter_phone: "all")
      # Pagination
      |> assign(page: 1)
      |> assign(total_pages: 1)
      |> assign(total: 0)
      |> assign(target_phone_id: nil)
      |> assign(phone_numbers: WhatsApp.list_phone_numbers())
      |> allow_upload(:header_media,
        accept: ~w(.jpg .jpeg .png .mp4 .3gp .pdf),
        max_entries: 1,
        max_file_size: 16_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> load_templates()

    {:ok, socket}
  end

  @impl true
  def handle_event("sync", _params, socket) do
    require Logger
    Logger.info("Template sync started")
    socket = assign(socket, syncing: true)
    parent = self()

    Task.start(fn ->
      try do
        Logger.info("Template sync Task running...")
        result = Templates.sync_from_meta()
        Logger.info("Template sync completed: #{inspect(result)}")
        send(parent, {:sync_complete, result})
      rescue
        e ->
          Logger.error("Template sync crashed: #{inspect(e)}")
          send(parent, {:sync_complete, {:error, e}})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("open_clone_modal", %{"id" => id}, socket) do
    template = Templates.get_template!(id)
    body_text = extract_body_text(template.components)

    timestamp = System.system_time(:second)

    # Detect original header type
    original_header_type = detect_header_type(template.components)

    {:noreply,
     socket
     |> assign(show_clone_modal: true)
     |> assign(cloning_template: template)
     |> assign(clone_name: "#{template.name}_copy_#{timestamp}")
     |> assign(clone_body_text: body_text)
     |> assign(clone_language: template.language || "en_US")
     |> assign(clone_buttons: extract_buttons(template.components))
     |> assign(clone_variables: extract_variables(body_text))
     |> assign(variable_values: %{})
     |> assign(target_phone_id: template.phone_number_id)
     |> assign(media_handle: nil)
     |> assign(uploaded_file: nil)
     |> assign(media_type: nil)
     |> assign(header_type: original_header_type)
     |> assign(upload_error: nil)}
  end

  @impl true
  def handle_event("close_clone_modal", _params, socket) do
    {:noreply, assign(socket, show_clone_modal: false)}
  end

  @impl true
  def handle_event("open_preview_modal", %{"id" => id}, socket) do
    template = Templates.get_template!(id)

    {:noreply,
     socket
     |> assign(show_preview_modal: true)
     |> assign(preview_template: template)}
  end

  @impl true
  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, assign(socket, show_preview_modal: false)}
  end

  @impl true
  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    template = Templates.get_template!(id)

    {:noreply,
     socket
     |> assign(show_delete_modal: true)
     |> assign(deleting_template: template)}
  end

  @impl true
  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, show_delete_modal: false, deleting_template: nil)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    template = socket.assigns.deleting_template

    case Templates.delete_template(template) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Template '#{template.name}' deleted successfully.")
         |> assign(show_delete_modal: false, deleting_template: nil)
         |> load_templates()}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete template.")
         |> assign(show_delete_modal: false, deleting_template: nil)}
    end
  end

  @impl true
  def handle_event("update_clone_form", params, socket) do
    require Logger
    Logger.debug("update_clone_form params: #{inspect(params)}")

    socket =
      socket
      |> assign(clone_name: params["clone_name"] || socket.assigns.clone_name)
      |> assign(clone_language: params["clone_language"] || socket.assigns.clone_language)

    {:noreply, socket}
  end

  # Keep old handler for backward compatibility
  @impl true
  def handle_event("update_clone_name", params, socket) do
    name = params["clone_name"] || params["value"] || socket.assigns.clone_name
    {:noreply, assign(socket, clone_name: name)}
  end

  @impl true
  def handle_event("update_clone_body", %{"body" => body}, socket) do
    {:noreply, assign(socket, clone_body_text: body)}
  end

  @impl true
  def handle_event("update_button_text", %{"index" => index_str, "value" => text}, socket) do
    index = String.to_integer(index_str)
    buttons = socket.assigns.clone_buttons

    updated_buttons = List.update_at(buttons, index, fn btn -> Map.put(btn, "text", text) end)

    {:noreply, assign(socket, clone_buttons: updated_buttons)}
  end

  @impl true
  def handle_event("update_button_url", %{"index" => index_str, "value" => url}, socket) do
    index = String.to_integer(index_str)
    buttons = socket.assigns.clone_buttons

    updated_buttons = List.update_at(buttons, index, fn btn -> Map.put(btn, "url", url) end)

    {:noreply, assign(socket, clone_buttons: updated_buttons)}
  end

  @impl true
  def handle_event("update_variable_value", %{"variable" => var, "value" => val}, socket) do
    values = Map.put(socket.assigns.variable_values, var, val)
    {:noreply, assign(socket, variable_values: values)}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_header_type", %{"type" => type}, socket) do
    # Clear uploaded file and update allowed file types when changing header type
    accept =
      case type do
        "image" -> ~w(.jpg .jpeg .png)
        "video" -> ~w(.mp4 .3gp)
        "document" -> ~w(.pdf)
        _ -> ~w(.jpg .jpeg .png .mp4 .3gp .pdf)
      end

    socket =
      socket
      |> assign(header_type: type)
      |> assign(uploaded_file: nil)
      |> assign(media_handle: nil)
      |> assign(media_type: nil)
      |> assign(upload_error: nil)
      |> allow_upload(:header_media,
        accept: accept,
        max_entries: 1,
        max_file_size: 16_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_upload", _params, socket) do
    # Clear the uploaded file
    socket =
      socket
      |> assign(uploaded_file: nil)
      |> assign(media_handle: nil)
      |> assign(media_type: nil)
      |> assign(upload_error: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :header_media, ref)}
  end

  # Unified filter handler for the filter form
  @impl true
  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(filter_search: params["search"] || socket.assigns.filter_search)
      |> assign(filter_phone: params["phone"] || socket.assigns.filter_phone)
      |> assign(filter_category: params["category"] || socket.assigns.filter_category)
      |> assign(filter_status: params["status"] || socket.assigns.filter_status)
      # Reset to page 1 on filter change
      |> assign(page: 1)
      |> load_templates()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)

    socket =
      socket
      |> assign(page: page)
      |> load_templates()

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_clone_language", params, socket) do
    require Logger
    Logger.debug("update_clone_language params: #{inspect(params)}")
    # Handle the select change which sends {"language" => code}
    language = params["language"] || socket.assigns.clone_language
    {:noreply, assign(socket, clone_language: language)}
  end

  @impl true
  def handle_event("update_target_phone", %{"target_phone" => phone_id}, socket) do
    {:noreply, assign(socket, target_phone_id: String.to_integer(phone_id))}
  end

  @impl true
  def handle_event("upload_header", _params, socket) do
    socket = assign(socket, uploading: true, upload_error: nil)

    # Process the upload
    case socket.assigns.uploads.header_media.entries do
      [entry | _] ->
        # Consume the upload and get the file path
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            # Get phone number for upload credentials
            phone_numbers = WhatsApp.list_phone_numbers()

            case phone_numbers do
              [phone | _] ->
                if is_nil(phone.app_id) or phone.app_id == "" do
                  {:error, "Facebook App ID not configured"}
                else
                  file_size = File.stat!(path).size
                  mime_type = get_mime_type(entry.client_name)

                  # Upload to Meta
                  MediaUploader.upload_for_template(
                    path,
                    file_size,
                    mime_type,
                    phone.app_id,
                    phone.access_token
                  )
                end

              [] ->
                {:error, :no_phone_numbers}
            end
          end)

        socket =
          case result do
            {:ok, handle} ->
              socket
              |> assign(media_handle: handle)
              |> assign(uploaded_file: entry.client_name)
              |> assign(uploading: false)

            {:error, reason} ->
              socket
              |> assign(upload_error: "Upload failed: #{inspect(reason)}")
              |> assign(uploading: false)
          end

        {:noreply, socket}

      [] ->
        {:noreply, assign(socket, uploading: false, upload_error: "No file selected")}
    end
  end

  def handle_event("create_clone", _params, socket) do
    template = socket.assigns.cloning_template
    target_phone_id = socket.assigns.target_phone_id

    # Find the selected phone number
    target_phone = Enum.find(socket.assigns.phone_numbers, fn p -> p.id == target_phone_id end)

    case target_phone do
      %{} = phone ->
        # Build components with updated body text and optional header
        components =
          build_clone_components(
            template.components,
            socket.assigns.clone_body_text,
            socket.assigns.media_handle,
            socket.assigns.media_type,
            socket.assigns.clone_buttons,
            socket.assigns.variable_values
          )

        case Templates.create_clone(
               template,
               socket.assigns.clone_name,
               components,
               socket.assigns.clone_language,
               phone.waba_id,
               phone.access_token
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Template clone created successfully! Pending approval.")
             |> assign(show_clone_modal: false)
             |> load_templates()}

          {:error, {:api_error, _, body}} ->
            error_msg = get_in(body, ["error", "message"]) || "API error"
            {:noreply, put_flash(socket, :error, "Clone failed: #{error_msg}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Clone failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Please select a phone number")}
    end
  end

  @impl true
  def handle_info({:sync_complete, result}, socket) do
    socket = assign(socket, syncing: false)

    socket =
      case result do
        {:ok, count} ->
          socket
          |> put_flash(:info, "Synced #{count} templates from Meta!")
          |> load_templates()

        {:error, :no_phone_numbers} ->
          put_flash(socket, :error, "No phone numbers configured. Add a phone number first.")

        {:error, reason} ->
          put_flash(socket, :error, "Sync failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:upload_complete, handle, filename, media_type}, socket) do
    {:noreply,
     socket
     |> assign(media_handle: handle)
     |> assign(uploaded_file: filename)
     |> assign(media_type: media_type)
     |> assign(uploading: false)}
  end

  @impl true
  def handle_info({:upload_error, reason}, socket) do
    {:noreply,
     socket
     |> assign(upload_error: "Upload failed: #{inspect(reason)}")
     |> assign(uploading: false)}
  end

  # Handle upload progress - auto-upload to Meta when file upload completes
  defp handle_progress(:header_media, entry, socket) do
    if entry.done? do
      # File has been uploaded to server, now upload to Meta
      socket = assign(socket, uploading: true, upload_error: nil)

      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        phone_numbers = WhatsApp.list_phone_numbers()

        case phone_numbers do
          [phone | _] ->
            # Check if app_id is configured
            if is_nil(phone.app_id) or phone.app_id == "" do
              send(
                self(),
                {:upload_error,
                 "Facebook App ID not configured. Please add it in Phone Numbers settings."}
              )

              {:error, :missing_app_id}
            else
              file_size = File.stat!(path).size
              mime_type = get_mime_type(entry.client_name)
              media_type = get_media_type(mime_type)

              case MediaUploader.upload_for_template(
                     path,
                     file_size,
                     mime_type,
                     phone.app_id,
                     phone.access_token
                   ) do
                {:ok, handle} ->
                  send(self(), {:upload_complete, handle, entry.client_name, media_type})
                  {:ok, handle}

                {:error, reason} ->
                  send(self(), {:upload_error, reason})
                  {:error, reason}
              end
            end

          [] ->
            send(self(), {:upload_error, :no_phone_numbers})
            {:error, :no_phone_numbers}
        end
      end)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp load_templates(socket) do
    filters = %{
      category: Map.get(socket.assigns, :filter_category, "all"),
      status: Map.get(socket.assigns, :filter_status, "all"),
      search: Map.get(socket.assigns, :filter_search, ""),
      phone: Map.get(socket.assigns, :filter_phone, "all")
    }

    page = Map.get(socket.assigns, :page, 1)
    result = Templates.list_templates(page, 25, filters)

    socket
    |> assign(templates: result.entries)
    |> assign(page: result.page)
    |> assign(total_pages: result.total_pages)
    |> assign(total: result.total)
  end

  defp extract_body_text(nil), do: ""

  defp extract_body_text(components) when is_list(components) do
    body = Enum.find(components, fn c -> c["type"] == "BODY" end)
    body["text"] || ""
  end

  defp extract_body_text(_), do: ""

  defp build_clone_components(
         original_components,
         body_text,
         media_handle,
         media_type,
         buttons,
         variable_values
       ) do
    components = original_components || []

    # Update BODY and BUTTONS
    components =
      Enum.map(components, fn comp ->
        cond do
          comp["type"] == "BODY" ->
            updated_comp = Map.put(comp, "text", body_text)

            # Add example variable values if provided
            if map_size(variable_values) > 0 do
              # Convert map values to list of strings in order
              examples =
                Regex.scan(~r/{{(\d+)}}/, body_text)
                |> Enum.map(fn [_, var] -> Map.get(variable_values, var, "example_#{var}") end)

              if Enum.empty?(examples) do
                updated_comp
              else
                Map.put(updated_comp, "example", %{"body_text" => [examples]})
              end
            else
              updated_comp
            end

          comp["type"] == "BUTTONS" && buttons ->
            Map.put(comp, "buttons", buttons)

          true ->
            comp
        end
      end)

    # Add HEADER with media if handle provided
    if media_handle do
      # Determine format based on media type
      format =
        case media_type do
          "video" -> "VIDEO"
          "image" -> "IMAGE"
          _ -> "DOCUMENT"
        end

      header = %{
        "type" => "HEADER",
        "format" => format,
        "example" => %{"header_handle" => [media_handle]}
      }

      [header | Enum.reject(components, fn c -> c["type"] == "HEADER" end)]
    else
      components
    end
  end

  defp get_mime_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".mp4" -> "video/mp4"
      ".3gp" -> "video/3gpp"
      ".pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end

  defp get_media_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      true -> "document"
    end
  end

  defp status_badge_class(status) do
    case status do
      "APPROVED" -> "bg-emerald-500/20 text-emerald-400 border-emerald-500/30"
      "PENDING" -> "bg-amber-500/20 text-amber-400 border-amber-500/30"
      "REJECTED" -> "bg-red-500/20 text-red-400 border-red-500/30"
      "PAUSED" -> "bg-zinc-700/50 text-zinc-400 border-zinc-700"
      _ -> "bg-zinc-700/50 text-zinc-400 border-zinc-700"
    end
  end

  defp extract_buttons(nil), do: nil

  defp extract_buttons(components) do
    case Enum.find(components, fn c -> c["type"] == "BUTTONS" end) do
      %{"buttons" => buttons} -> buttons
      _ -> nil
    end
  end

  defp extract_footer(components) do
    case Enum.find(components, fn c -> c["type"] == "FOOTER" end) do
      %{"text" => text} -> text
      _ -> nil
    end
  end

  defp detect_header_type(nil), do: "none"

  defp detect_header_type(components) do
    case Enum.find(components, fn c -> c["type"] == "HEADER" end) do
      %{"format" => "TEXT"} -> "text"
      %{"format" => "IMAGE"} -> "image"
      %{"format" => "VIDEO"} -> "video"
      %{"format" => "DOCUMENT"} -> "document"
      _ -> "none"
    end
  end

  defp extract_variables(text) do
    Regex.scan(~r/{{(\d+)}}/, text)
    |> Enum.map(fn [_, var] -> var end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp button_icon("QUICK_REPLY"), do: "↩️"
  defp button_icon("URL"), do: "🔗"
  defp button_icon("PHONE_NUMBER"), do: "📞"
  defp button_icon(_), do: "⏺️"

  defp preview_body_text(text, variable_values) when is_binary(text) do
    Regex.replace(~r/{{(\d+)}}/, text, fn _, var ->
      case Map.get(variable_values, var) do
        nil -> "{{#{var}}}"
        "" -> "{{#{var}}}"
        value -> value
      end
    end)
  end

  defp preview_body_text(_, _), do: ""

  # Client-side filtering removed - now handled server-side in Templates context

  defp language_options do
    [
      {"English", "en"},
      {"English (UAE)", "en_AE"},
      {"English (AUS)", "en_AU"},
      {"English (CAN)", "en_CA"},
      {"English (UK)", "en_GB"},
      {"English (GHA)", "en_GH"},
      {"English (IRL)", "en_IE"},
      {"English (IND)", "en_IN"},
      {"English (JAM)", "en_JM"},
      {"English (MYS)", "en_MY"},
      {"English (NZL)", "en_NZ"},
      {"English (QAT)", "en_QA"},
      {"English (SGP)", "en_SG"},
      {"English (US)", "en_US"},
      {"English (UGA)", "en_UG"},
      {"English (ZAF)", "en_ZA"},
      {"Hindi", "hi"},
      {"Spanish", "es"},
      {"Portuguese (BR)", "pt_BR"},
      {"French", "fr"},
      {"German", "de"},
      {"Italian", "it"},
      {"Indonesian", "id"},
      {"Arabic", "ar"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Templates <span class="ml-2 px-2.5 py-0.5 rounded-full bg-base-300 text-sm font-normal text-base-content/70"><%= @total %></span></h1>
          <p class="text-base-content/60 text-sm mt-1">Manage your WhatsApp message templates</p>
        </div>
        <button
          phx-click="sync"
          disabled={@syncing}
          class="px-4 py-2 bg-primary text-primary-content rounded-lg font-medium text-sm hover:bg-primary/90 transition-colors disabled:opacity-50 shadow-sm"
        >
          <%= if @syncing do %>
            <span class="animate-spin inline-block">⟳</span> Syncing...
          <% else %>
            🔄 Sync All
          <% end %>
        </button>
      </div>

      <!-- Filter Bar -->
      <form phx-change="filter" class="bg-base-100 rounded-xl border border-base-200 p-4 shadow-sm">
        <div class="flex flex-wrap items-center gap-4">
          <!-- Search -->
          <div class="flex-1 min-w-[200px]">
            <input
              type="text"
              name="search"
              value={@filter_search}
              phx-debounce="300"
              placeholder="🔍 Search templates..."
              class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-4 py-2 text-base-content text-sm focus:outline-none"
            />
          </div>
          
          <!-- Phone Number Filter -->
          <select
            name="phone"
            class="bg-base-200 border border-transparent focus:border-primary rounded-lg px-4 py-2 text-base-content text-sm focus:outline-none"
          >
            <option value="all" selected={@filter_phone == "all"}>All Numbers</option>
            <%= for phone_name <- @templates |> Enum.map(& &1.phone_display_name) |> Enum.uniq() |> Enum.reject(&is_nil/1) do %>
              <option value={phone_name} selected={@filter_phone == phone_name}><%= phone_name %></option>
            <% end %>
          </select>
          
          <!-- Category Filter -->
          <select
            name="category"
            class="bg-base-200 border border-transparent focus:border-primary rounded-lg px-4 py-2 text-base-content text-sm focus:outline-none"
          >
            <option value="all" selected={@filter_category == "all"}>All Categories</option>
            <option value="utility" selected={@filter_category == "utility"}>Utility</option>
            <option value="marketing" selected={@filter_category == "marketing"}>Marketing</option>
            <option value="authentication" selected={@filter_category == "authentication"}>Authentication</option>
          </select>
          
          <!-- Status Filter -->
          <select
            name="status"
            class="bg-base-200 border border-transparent focus:border-primary rounded-lg px-4 py-2 text-base-content text-sm focus:outline-none"
          >
            <option value="all" selected={@filter_status == "all"}>All Statuses</option>
            <option value="approved" selected={@filter_status == "approved"}>✅ Approved</option>
            <option value="pending" selected={@filter_status == "pending"}>⏳ Pending</option>
            <option value="rejected" selected={@filter_status == "rejected"}>❌ Rejected</option>
            <option value="paused" selected={@filter_status == "paused"}>⏸️ Paused</option>
          </select>
        </div>
      </form>

      <!-- Templates Table -->
      <div class="bg-base-100 rounded-xl border border-base-200 shadow-sm overflow-hidden">
        <%= if Enum.empty?(@templates) do %>
          <div class="p-12 text-center">
            <span class="text-4xl">📄</span>
            <p class="mt-4 text-base-content/60">No templates found.</p>
            <p class="mt-2 text-base-content/50 text-sm">
              Add a phone number and click "Sync from Meta" to import templates.
            </p>
          </div>
        <% else %>
          <table class="w-full">
            <thead class="bg-primary/5 border-b border-base-200">
              <tr>
                <th class="text-left px-4 py-3 text-xs font-semibold text-base-content/70 uppercase tracking-wider">Template</th>
                <th class="text-left px-4 py-3 text-xs font-semibold text-base-content/70 uppercase tracking-wider">Language</th>
                <th class="text-left px-4 py-3 text-xs font-semibold text-base-content/70 uppercase tracking-wider">Category</th>
                <th class="text-left px-4 py-3 text-xs font-semibold text-base-content/70 uppercase tracking-wider">Phone Number</th>
                <th class="text-right px-4 py-3 text-xs font-semibold text-base-content/70 uppercase tracking-wider">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <%= for template <- @templates do %>
                <tr class="hover:bg-base-50 transition-colors">
                  <td class="px-4 py-4">
                    <div class="flex items-center gap-3">
                      <div>
                        <div class="flex items-center gap-2">
                          <span class="font-semibold text-base-content"><%= template.name %></span>
                          <span class={"px-2 py-0.5 rounded-full text-xs font-bold border #{status_badge_class(template.status)}"}>
                            <%= if template.status == "APPROVED" do %>✓<% end %> <%= template.status || "UNKNOWN" %>
                          </span>
                          <%= if template.status == "PENDING" do %>
                            <span class="text-xs text-base-content/50">• Reviewing</span>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="px-4 py-4">
                    <span class="text-sm text-base-content/70"><%= template.language || "en_GB" %></span>
                  </td>
                  <td class="px-4 py-4">
                    <span class={"px-2 py-1 rounded text-xs font-medium " <> 
                      if(template.category == "MARKETING", do: "bg-success/20 text-success", else: "bg-base-200 text-base-content/70")}>
                      <%= template.category || "UTILITY" %>
                    </span>
                  </td>
                  <td class="px-4 py-4">
                    <span class="text-sm text-base-content/70"><%= template.phone_display_name || "—" %></span>
                  </td>
                  <td class="px-4 py-4">
                    <div class="flex items-center justify-end gap-1">
                      <button 
                        phx-click="open_preview_modal"
                        phx-value-id={template.id}
                        class="px-3 py-1.5 bg-success text-success-content text-xs font-medium rounded-lg hover:bg-success/90 transition-colors flex items-center gap-1"
                      >
                        👁️ Preview
                      </button>
                      <button
                        phx-click="open_clone_modal"
                        phx-value-id={template.id}
                        class="p-2 rounded-lg text-base-content/50 hover:bg-base-200 hover:text-base-content transition-colors"
                        title="Duplicate"
                      >
                        📋
                      </button>
                      <button
                        phx-click="open_delete_modal"
                        phx-value-id={template.id}
                        class="p-2 rounded-lg text-error/50 hover:bg-error/10 hover:text-error transition-colors"
                        title="Delete"
                      >
                        🗑️
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
          
          <!-- Pagination -->
          <%= if @total_pages > 1 do %>
            <div class="px-4 py-3 border-t border-base-200 flex items-center justify-between bg-base-100/50">
              <p class="text-sm text-base-content/60">
                Showing <%= (@page - 1) * 25 + 1 %> - <%= min(@page * 25, @total) %> of <%= @total %> templates
              </p>
              <div class="flex items-center gap-1">
                <button
                  phx-click="change_page"
                  phx-value-page={max(1, @page - 1)}
                  disabled={@page == 1}
                  class="px-3 py-1.5 rounded-lg text-sm font-medium bg-base-200 text-base-content/70 hover:bg-base-300 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  ← Prev
                </button>
                <%= for p <- max(1, @page - 2)..min(@total_pages, @page + 2) do %>
                  <button
                    phx-click="change_page"
                    phx-value-page={p}
                    class={"px-3 py-1.5 rounded-lg text-sm font-medium transition-colors " <>
                      if(p == @page, do: "bg-primary text-primary-content", else: "bg-base-200 text-base-content/70 hover:bg-base-300")}
                  >
                    <%= p %>
                  </button>
                <% end %>
                <button
                  phx-click="change_page"
                  phx-value-page={min(@total_pages, @page + 1)}
                  disabled={@page == @total_pages}
                  class="px-3 py-1.5 rounded-lg text-sm font-medium bg-base-200 text-base-content/70 hover:bg-base-300 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Next →
                </button>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>

    <!-- Clone Modal -->
    <%= if @show_clone_modal do %>
      <div class="fixed inset-0 z-50 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="fixed inset-0 bg-neutral/60 backdrop-blur-sm" phx-click="close_clone_modal"></div>
          
          <div class="relative bg-base-100 rounded-2xl shadow-xl w-full max-w-5xl border border-base-200">
            <!-- Modal Header -->
            <div class="p-5 border-b border-base-200 flex justify-between items-center bg-primary/5 rounded-t-2xl">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 bg-primary/20 rounded-lg flex items-center justify-center">
                  <span class="text-primary text-lg">📋</span>
                </div>
                <div>
                  <div class="flex items-center gap-2">
                    <h2 class="text-xl font-bold text-base-content">Duplicate</h2>
                    <span class="px-2 py-0.5 bg-primary/20 text-primary text-xs font-medium rounded">Clone</span>
                  </div>
                  <p class="text-base-content/60 text-sm">Cloning "<%= @cloning_template.name %>"</p>
                </div>
              </div>
              <button phx-click="close_clone_modal" class="w-8 h-8 flex items-center justify-center rounded-full bg-base-200 text-base-content/60 hover:bg-base-300 hover:text-base-content transition-colors">✕</button>
            </div>
            
            <!-- Modal Body - Two Column Layout -->
            <div class="flex">
              <!-- Left Column - Form -->
              <div class="flex-1 p-6 space-y-6 border-r border-base-200 max-h-[70vh] overflow-y-auto">
                
                <!-- Basic Information Section -->
                <form phx-change="update_clone_form" phx-debounce="300" class="space-y-4">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                    <span class="text-primary">📝</span> Basic Information
                  </div>
                  
                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-xs font-medium text-base-content/70 mb-1.5">📄 Template Name *</label>
                      <input
                        type="text"
                        name="clone_name"
                        value={@clone_name}
                        class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-3 py-2.5 text-base-content placeholder-base-content/40 focus:outline-none transition-colors text-sm"
                      />
                      <p class="mt-1 text-xs text-base-content/40">lowercase, numbers, _</p>
                    </div>
                    <div>
                      <label class="block text-xs font-medium text-base-content/70 mb-1.5">🌐 Language</label>
                      <select
                        name="clone_language"
                        class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-3 py-2.5 text-base-content text-sm focus:outline-none"
                      >
                        <%= for {label, code} <- language_options() do %>
                          <option value={code} selected={@clone_language == code}><%= label %></option>
                        <% end %>
                      </select>
                    </div>
                  </div>
                </form>
                
                <div class="space-y-4">
                  <div>
                    <label class="block text-xs font-medium text-base-content/70 mb-1.5">📞 Target Phone Number</label>
                    <select
                      name="target_phone"
                      phx-change="update_target_phone"
                      class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-3 py-2.5 text-base-content text-sm focus:outline-none"
                    >
                      <%= for phone <- @phone_numbers do %>
                        <option value={phone.id} selected={@target_phone_id == phone.id}>
                          <%= phone.display_name || phone.mobile_number %>
                        </option>
                      <% end %>
                    </select>
                    <p class="mt-1 text-xs text-warning/70" :if={@target_phone_id != @cloning_template.phone_number_id}>
                      ⚠️ Ensure media handles are valid for this WABA.
                    </p>
                  </div>
                  
                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-xs font-medium text-base-content/70 mb-1.5">🏷️ Category</label>
                      <div class="w-full bg-base-200 rounded-lg px-3 py-2.5 text-base-content text-sm">
                        <%= @cloning_template.category || "UTILITY" %>
                      </div>
                    </div>
                  </div>
                </div>

                <!-- Header Section -->
                <div class="space-y-4 pt-4 border-t border-base-200">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                    <span class="w-5 h-5 bg-error/20 rounded flex items-center justify-center text-xs">🎬</span> 
                    Header (Optional)
                  </div>
                  
                  <!-- Header Type Selector -->
                  <div class="flex items-center gap-1 p-1 bg-base-200 rounded-lg">
                    <button type="button" phx-click="set_header_type" phx-value-type="image"
                      class={"px-4 py-2 rounded text-sm font-medium transition-colors flex items-center gap-1.5 " <>
                        if(@header_type == "image", do: "bg-base-100 shadow-sm text-base-content", else: "text-base-content/60 hover:text-base-content")}>
                      🖼 Image
                    </button>
                    <button type="button" phx-click="set_header_type" phx-value-type="video"
                      class={"px-4 py-2 rounded text-sm font-medium transition-colors flex items-center gap-1.5 " <>
                        if(@header_type == "video", do: "bg-primary text-primary-content shadow-sm", else: "text-base-content/60 hover:text-base-content")}>
                      🎬 Video
                    </button>
                  </div>

                  <!-- File Upload (shown when image/video/document selected) -->
                  <%= if @header_type in ["image", "video", "document"] do %>
                    <form id="upload-form" phx-change="validate_upload">
                      <%= if @uploaded_file do %>
                        <!-- File Ready State -->
                        <div class="flex items-center gap-3 p-3 bg-success/10 border border-success/30 rounded-lg">
                          <span class="text-success text-xl">✓</span>
                          <div class="flex-1">
                            <p class="font-medium text-base-content text-sm"><%= @uploaded_file %></p>
                            <p class="text-xs text-success">✓ Ready to use</p>
                          </div>
                          <button type="button" phx-click="remove_upload" class="p-2 hover:bg-base-200 rounded transition-colors" title="Remove">
                            <span class="text-error">✕</span>
                          </button>
                        </div>
                      <% else %>
                        <%= if @uploading do %>
                          <!-- Uploading State -->
                          <div class="flex items-center gap-3 p-4 bg-base-200/50 border border-base-300 rounded-lg">
                            <span class="text-xl animate-spin">⟳</span>
                            <div>
                              <p class="font-medium text-base-content text-sm">Uploading to Meta...</p>
                              <p class="text-xs text-base-content/60">Please wait</p>
                            </div>
                          </div>
                        <% else %>
                          <%= for entry <- @uploads.header_media.entries do %>
                            <!-- Upload Progress State -->
                            <div class="flex items-center gap-3 p-3 bg-base-200/50 border border-base-300 rounded-lg">
                              <span class="text-xl">📎</span>
                              <div class="flex-1">
                                <p class="font-medium text-base-content text-sm"><%= entry.client_name %></p>
                                <div class="w-full h-1.5 bg-base-300 rounded-full mt-1.5">
                                  <div class="h-full bg-primary rounded-full transition-all" style={"width: #{entry.progress}%"}></div>
                                </div>
                                <p class="text-xs text-base-content/50 mt-1">
                                  <%= if entry.progress < 100, do: "Uploading... #{entry.progress}%", else: "Preparing for Meta upload..." %>
                                </p>
                              </div>
                              <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref} class="text-error hover:text-error/70">
                                ✕
                              </button>
                            </div>
                          <% end %>
                          
                          <%= if Enum.empty?(@uploads.header_media.entries) do %>
                            <!-- Empty Upload State -->
                            <label for={@uploads.header_media.ref} class="cursor-pointer block">
                              <div class="border-2 border-dashed border-base-300 rounded-lg p-6 text-center hover:border-primary/50 transition-colors bg-base-200/30">
                                <span class="text-3xl text-base-content/30">📁</span>
                                <p class="mt-2 text-base-content/60 text-sm">Drop <%= @header_type %> here or click to browse</p>
                                <p class="text-xs text-base-content/40 mt-1">
                                  <%= case @header_type do %>
                                    <% "image" -> %>JPG, PNG (max 16MB)
                                    <% "video" -> %>MP4, 3GP (max 16MB)
                                    <% "document" -> %>PDF (max 16MB)
                                    <% _ -> %>JPG, PNG, MP4, 3GP, PDF (max 16MB)
                                  <% end %>
                                </p>
                              </div>
                            </label>
                          <% end %>
                        <% end %>
                      <% end %>
                      
                      <.live_file_input upload={@uploads.header_media} class="sr-only" />
                      
                      <%= if @upload_error do %>
                        <p class="mt-2 text-error text-sm"><%= @upload_error %></p>
                      <% end %>
                    </form>
                  <% end %>
                </div>

                <!-- Message Body Section -->
                <div class="space-y-4 pt-4 border-t border-base-200">
                  <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                    <span class="w-5 h-5 bg-primary/20 rounded flex items-center justify-center text-xs">💬</span> 
                    Message Body *
                  </div>
                  
                  <textarea
                    rows="4"
                    phx-blur="update_clone_body"
                    phx-value-body={@clone_body_text}
                    class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-4 py-3 text-base-content placeholder-base-content/40 focus:outline-none transition-colors resize-none text-sm"
                  ><%= @clone_body_text %></textarea>
                  <p class="text-xs text-base-content/50">Use &#123;&#123;1&#125;&#125;, &#123;&#123;2&#125;&#125; for variables. Max 1024 characters.</p>
                </div>

                <!-- Variable Inputs -->
                <%= if @clone_variables && length(@clone_variables) > 0 do %>
                  <div class="space-y-4 pt-4 border-t border-base-200">
                    <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                      <span class="text-primary">🔢</span> Template Variables
                    </div>
                    <p class="text-xs text-base-content/50">Provide example values for variables (Required by Meta)</p>
                    <div class="grid grid-cols-2 gap-4">
                      <%= for var <- @clone_variables do %>
                        <div>
                          <label class="block text-xs font-medium text-base-content/70 mb-1">Variable &lbrace;&lbrace;<%= var %>&rbrace;&rbrace;</label>
                          <input 
                            type="text" 
                            placeholder={"Value for {{#{var}}}"}
                            value={Map.get(@variable_values, var, "")}
                            phx-blur="update_variable_value" 
                            phx-value-variable={var}
                            class="w-full bg-base-200 border border-transparent focus:border-primary rounded-lg px-3 py-2 text-sm text-base-content focus:outline-none transition-colors"
                          />
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <!-- Buttons Section -->
                <%= if @clone_buttons && length(@clone_buttons) > 0 do %>
                  <div class="space-y-4 pt-4 border-t border-base-200">
                    <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                      <span class="text-primary">🔘</span> Buttons (Editable)
                    </div>
                    <div class="space-y-3">
                      <%= for {button, index} <- Enum.with_index(@clone_buttons) do %>
                        <div class="bg-base-200/50 p-3 rounded-lg border border-base-300/50 space-y-2">
                          <div class="flex items-center gap-2">
                            <span class="text-primary"><%= button_icon(button["type"]) %></span>
                            <span class="text-xs text-base-content/50 uppercase font-medium"><%= button["type"] %></span>
                          </div>
                          
                          <div>
                            <label class="text-xs text-base-content/50">Button Text</label>
                            <input 
                              type="text" 
                              value={button["text"]} 
                              phx-blur="update_button_text" 
                              phx-value-index={index}
                              class="w-full bg-base-100 border border-base-300 focus:border-primary rounded px-3 py-2 text-sm text-base-content focus:outline-none"
                            />
                          </div>

                          <%= if button["type"] == "URL" do %>
                            <div>
                              <label class="text-xs text-base-content/50">Website URL</label>
                              <input 
                                type="text" 
                                value={button["url"]} 
                                phx-blur="update_button_url" 
                                phx-value-index={index}
                                class="w-full bg-base-100 border border-base-300 focus:border-primary rounded px-3 py-2 text-sm text-base-content focus:outline-none"
                              />
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <!-- Footer -->
                <%= if footer = extract_footer(@cloning_template.components) do %>
                  <div class="space-y-4 pt-4 border-t border-base-200">
                    <div class="flex items-center gap-2 text-sm font-medium text-base-content">
                      <span class="text-base-content/50">📝</span> Footer (Will be copied)
                    </div>
                    <div class="bg-base-200/50 rounded-lg p-3 text-sm text-base-content/60 italic border border-base-300/50">
                      <%= footer %>
                    </div>
                  </div>
                <% end %>
              </div>
              
              <!-- Right Column - Live Preview -->
              <div class="w-80 p-6 bg-base-200/30">
                <div class="flex items-center gap-2 mb-4">
                  <span class="text-success">👁</span>
                  <span class="font-medium text-sm text-base-content">LIVE PREVIEW</span>
                </div>
                
                <!-- Phone Mockup -->
                <div class="bg-base-100 rounded-2xl shadow-lg overflow-hidden border border-base-200">
                  <!-- Phone Header -->
                  <div class="bg-primary/10 p-3 flex items-center gap-2">
                    <div class="w-8 h-8 bg-primary/20 rounded-full flex items-center justify-center text-sm">👤</div>
                    <div>
                      <p class="font-medium text-sm text-base-content">Customer</p>
                      <p class="text-xs text-success">● online</p>
                    </div>
                  </div>
                  
                  <!-- Message Area -->
                  <div class="p-4 bg-gradient-to-b from-base-200/50 to-base-100 min-h-[300px]">
                    <!-- Message Bubble -->
                    <div class="bg-base-100 rounded-lg shadow-sm p-3 max-w-[90%] border border-base-200">
                      <!-- Header Preview -->
                      <%= if @header_type in ["image", "video"] and @uploaded_file do %>
                        <div class="bg-gradient-to-br from-primary/10 to-primary/5 rounded-lg mb-3 p-4 text-center">
                          <span class="text-2xl"><%= if @header_type == "video", do: "🎬", else: "🖼" %></span>
                          <p class="text-xs text-base-content/50 mt-1"><%= @header_type |> String.upcase() %></p>
                        </div>
                      <% end %>
                      
                      <!-- Body Preview -->
                      <p class="text-sm text-base-content whitespace-pre-wrap"><%= preview_body_text(@clone_body_text, @variable_values) %></p>
                      
                      <!-- Timestamp -->
                      <p class="text-xs text-base-content/40 text-right mt-2"><%= DateTimeHelpers.format_time(DateTime.utc_now()) %> ✓✓</p>
                    </div>
                    
                    <!-- Buttons Preview -->
                    <%= if @clone_buttons && length(@clone_buttons) > 0 do %>
                      <div class="mt-2 space-y-1">
                        <%= for button <- @clone_buttons do %>
                          <div class="bg-base-100 rounded-lg p-2 text-center text-sm text-primary border border-base-200 shadow-sm">
                            <%= button_icon(button["type"]) %> <%= button["text"] %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
                
                <!-- Quick Tips -->
                <div class="mt-4 p-3 bg-base-100 rounded-lg border border-base-200">
                  <p class="font-medium text-sm text-base-content mb-2">💡 Quick Tips</p>
                  <ul class="text-xs text-base-content/60 space-y-1">
                    <li>🌟 Use variables for personalization</li>
                    <li>✓ Keep messages concise and clear</li>
                    <li>⚠️ Templates are reviewed by WhatsApp</li>
                  </ul>
                </div>
              </div>
            </div>
            
            <!-- Modal Footer -->
            <div class="p-5 border-t border-base-200 flex items-center justify-end gap-3 bg-base-100 rounded-b-2xl">
              <button
                phx-click="close_clone_modal"
                class="px-5 py-2.5 bg-base-200 text-base-content/70 rounded-lg font-medium text-sm hover:bg-base-300 transition-colors flex items-center gap-2"
              >
                ⊗ Cancel
              </button>
              <button
                phx-click="create_clone"
                phx-disable-with="⏳ Creating..."
                class="px-5 py-2.5 bg-primary text-primary-content rounded-lg font-medium text-sm hover:bg-primary/90 transition-colors shadow-sm flex items-center gap-2 disabled:opacity-50 disabled:cursor-wait active:scale-95"
              >
                📋 Duplicate Template
              </button>
            </div>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @show_preview_modal do %>
      <div class="fixed inset-0 z-50 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="fixed inset-0 bg-neutral/60 backdrop-blur-sm" phx-click="close_preview_modal"></div>
          
          <div class="relative bg-base-100 rounded-2xl shadow-xl w-full max-w-lg border border-base-200">
            <!-- Modal Header -->
            <div class="p-5 border-b border-base-200 flex justify-between items-center bg-primary/5 rounded-t-2xl">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 bg-success/20 rounded-lg flex items-center justify-center">
                  <span class="text-success text-lg">👁️</span>
                </div>
                <div>
                  <h2 class="text-xl font-bold text-base-content">Template Preview</h2>
                  <p class="text-base-content/60 text-sm"><%= @preview_template.name %></p>
                </div>
              </div>
              <button phx-click="close_preview_modal" class="w-8 h-8 flex items-center justify-center rounded-full bg-base-200 text-base-content/60 hover:bg-base-300 hover:text-base-content transition-colors">✕</button>
            </div>
            
            <!-- Modal Body -->
            <div class="p-6 bg-base-200/30">
              <!-- Phone Mockup -->
              <div class="bg-base-100 rounded-2xl shadow-lg overflow-hidden border border-base-200 max-w-xs mx-auto">
                <!-- Phone Header -->
                <div class="bg-primary/10 p-3 flex items-center gap-2">
                  <div class="w-8 h-8 bg-primary/20 rounded-full flex items-center justify-center text-sm">👤</div>
                  <div>
                    <p class="font-medium text-sm text-base-content">Customer</p>
                    <p class="text-xs text-success">● online</p>
                  </div>
                </div>
                
                <!-- Message Area -->
                <div class="p-4 bg-gradient-to-b from-base-200/50 to-base-100 min-h-[250px]">
                  <!-- Message Bubble -->
                  <div class="bg-base-100 rounded-lg shadow-sm p-3 max-w-[90%] border border-base-200">
                    <!-- Header Preview -->
                    <% header = Enum.find(@preview_template.components || [], fn c -> c["type"] == "HEADER" end) %>
                    <%= if header do %>
                      <div class="bg-gradient-to-br from-primary/10 to-primary/5 rounded-lg mb-3 p-4 text-center">
                        <span class="text-2xl">
                          <%= case header["format"] do %>
                            <% "IMAGE" -> %> 🖼
                            <% "VIDEO" -> %> 🎬
                            <% "DOCUMENT" -> %> 📄
                            <% _ -> %> 📝
                          <% end %>
                        </span>
                        <p class="text-xs text-base-content/50 mt-1"><%= header["format"] || "HEADER" %></p>
                      </div>
                    <% end %>
                    
                    <!-- Body Preview -->
                    <% body = Enum.find(@preview_template.components || [], fn c -> c["type"] == "BODY" end) %>
                    <p class="text-sm text-base-content whitespace-pre-wrap"><%= if body, do: body["text"], else: "" %></p>
                    
                    <!-- Footer Preview -->
                    <% footer = Enum.find(@preview_template.components || [], fn c -> c["type"] == "FOOTER" end) %>
                    <%= if footer do %>
                      <p class="text-xs text-base-content/50 mt-2 italic"><%= footer["text"] %></p>
                    <% end %>
                    
                    <!-- Timestamp -->
                    <p class="text-xs text-base-content/40 text-right mt-2"><%= DateTimeHelpers.format_time(DateTime.utc_now()) %> ✓✓</p>
                  </div>
                  
                  <!-- Buttons Preview -->
                  <% buttons_component = Enum.find(@preview_template.components || [], fn c -> c["type"] == "BUTTONS" end) %>
                  <%= if buttons_component && buttons_component["buttons"] do %>
                    <div class="mt-2 space-y-1">
                      <%= for button <- buttons_component["buttons"] do %>
                        <div class="bg-base-100 rounded-lg p-2 text-center text-sm text-primary border border-base-200 shadow-sm">
                          <%= button_icon(button["type"]) %> <%= button["text"] %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
              
              <!-- Template Info -->
              <div class="mt-4 grid grid-cols-3 gap-3 text-center">
                <div class="bg-base-100 rounded-lg p-3 border border-base-200">
                  <p class="text-xs text-base-content/50">Status</p>
                  <p class="font-medium text-sm text-base-content"><%= @preview_template.status || "—" %></p>
                </div>
                <div class="bg-base-100 rounded-lg p-3 border border-base-200">
                  <p class="text-xs text-base-content/50">Category</p>
                  <p class="font-medium text-sm text-base-content"><%= @preview_template.category || "—" %></p>
                </div>
                <div class="bg-base-100 rounded-lg p-3 border border-base-200">
                  <p class="text-xs text-base-content/50">Language</p>
                  <p class="font-medium text-sm text-base-content"><%= @preview_template.language || "—" %></p>
                </div>
              </div>
            </div>
            
            <!-- Modal Footer -->
            <div class="p-4 border-t border-base-200 flex justify-end bg-base-100 rounded-b-2xl">
              <button
                phx-click="close_preview_modal"
                class="px-5 py-2.5 bg-primary text-primary-content rounded-lg font-medium text-sm hover:bg-primary/90 transition-colors"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      </div>
    <% end %>

    <%= if @show_delete_modal && @deleting_template do %>
      <div class="fixed inset-0 z-50 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="fixed inset-0 bg-neutral/60 backdrop-blur-sm" phx-click="close_delete_modal"></div>
          
          <div class="relative bg-base-100 rounded-2xl shadow-xl w-full max-w-md border border-base-200">
            <!-- Modal Header -->
            <div class="p-5 border-b border-base-200 flex justify-between items-center bg-error/5 rounded-t-2xl">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 bg-error/20 rounded-lg flex items-center justify-center">
                  <span class="text-error text-lg">⚠️</span>
                </div>
                <div>
                  <h2 class="text-xl font-bold text-base-content">Delete Template</h2>
                  <p class="text-base-content/60 text-sm">This action cannot be undone</p>
                </div>
              </div>
              <button phx-click="close_delete_modal" class="w-8 h-8 flex items-center justify-center rounded-full bg-base-200 text-base-content/60 hover:bg-base-300 hover:text-base-content transition-colors">✕</button>
            </div>
            
            <!-- Modal Body -->
            <div class="p-6">
              <p class="text-base-content">Are you sure you want to delete the template:</p>
              <p class="mt-2 font-semibold text-lg text-base-content"><%= @deleting_template.name %></p>
              <p class="mt-4 text-sm text-base-content/60">
                This will remove the template from your local database. You can re-sync from Meta to restore it.
              </p>
            </div>
            
            <!-- Modal Footer -->
            <div class="p-5 border-t border-base-200 flex items-center justify-end gap-3 bg-base-100 rounded-b-2xl">
              <button
                phx-click="close_delete_modal"
                class="px-5 py-2.5 bg-base-200 text-base-content/70 rounded-lg font-medium text-sm hover:bg-base-300 transition-colors"
              >
                Cancel
              </button>
              <button
                phx-click="confirm_delete"
                class="px-5 py-2.5 bg-error text-error-content rounded-lg font-medium text-sm hover:bg-error/90 transition-colors shadow-sm"
              >
                🗑️ Delete Template
              </button>
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
