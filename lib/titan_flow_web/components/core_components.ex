defmodule TitanFlowWeb.CoreComponents do
  @moduledoc """
  Provides core UI components with Linear-style dark theme.
  """
  use Phoenix.Component

  # Import helper for generating URLs
  use Phoenix.VerifiedRoutes,
    endpoint: TitanFlowWeb.Endpoint,
    router: TitanFlowWeb.Router,
    statics: TitanFlowWeb.static_paths()

  @doc """
  Navigation link component for sidebar.
  """
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def nav_link(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-md text-sm font-medium transition-colors",
        @active && "bg-zinc-800 text-zinc-100",
        !@active && "text-zinc-400 hover:bg-zinc-800/50 hover:text-zinc-100"
      ]}
    >
      <span class="text-base"><%= @icon %></span>
      <span><%= @label %></span>
    </a>
    """
  end

  @doc """
  Flash message group component.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div class="fixed bottom-4 right-4 z-50 space-y-2">
      <.flash :if={@flash["info"]} kind={:info} message={@flash["info"]} />
      <.flash :if={@flash["error"]} kind={:error} message={@flash["error"]} />
    </div>
    """
  end

  @doc """
  Individual flash message component.
  """
  attr :kind, :atom, required: true
  attr :message, :string, required: true

  def flash(assigns) do
    ~H"""
    <div class={[
      "px-4 py-3 rounded-lg shadow-lg text-sm font-medium border",
      @kind == :info && "bg-indigo-500/20 text-indigo-300 border-indigo-500/30",
      @kind == :error && "bg-red-500/20 text-red-300 border-red-500/30"
    ]}>
      <%= @message %>
    </div>
    """
  end

  @doc """
  Page header component.
  """
  attr :title, :string, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-6">
      <h1 class="text-xl font-semibold text-zinc-100"><%= @title %></h1>
      <div class="flex items-center gap-3">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  @doc """
  Card component for dashboard stats.
  """
  attr :title, :string, required: true
  attr :value, :string, required: true
  attr :icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="bg-zinc-900 rounded-lg p-5 border border-zinc-800">
      <div class="flex items-center justify-between">
        <p class="text-zinc-400 text-sm font-medium"><%= @title %></p>
        <span :if={@icon} class="text-xl"><%= @icon %></span>
      </div>
      <p class="mt-2 text-2xl font-bold text-zinc-100 font-mono"><%= @value %></p>
    </div>
    """
  end

  @doc """
  Button component with variants.
  """
  attr :type, :string, default: "button"
  attr :variant, :atom, default: :primary
  attr :size, :atom, default: :default
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center font-medium transition-colors",
        "focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-zinc-700",
        # Size variants
        @size == :default && "h-9 px-4 rounded-md text-sm",
        @size == :sm && "h-8 px-3 rounded text-sm",
        @size == :xs && "h-7 px-2.5 rounded text-xs",
        # Color variants
        @variant == :primary && "bg-indigo-600 hover:bg-indigo-500 text-white",
        @variant == :secondary && "bg-zinc-800 hover:bg-zinc-700 text-zinc-100 border border-zinc-700",
        @variant == :danger && "bg-red-600 hover:bg-red-500 text-white",
        @variant == :ghost && "bg-transparent hover:bg-zinc-800 text-zinc-400 hover:text-zinc-100",
        @variant == :success && "bg-emerald-600 hover:bg-emerald-500 text-white",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Input component with dark theme styling.
  """
  attr :type, :string, default: "text"
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: ""
  attr :class, :string, default: ""
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      value={@value}
      placeholder={@placeholder}
      class={[
        "h-9 px-3 rounded-md text-sm font-medium transition-colors w-full",
        "bg-zinc-900 border border-zinc-800 text-zinc-100",
        "placeholder-zinc-500",
        "hover:border-zinc-700",
        "focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500",
        @class
      ]}
      {@rest}
    />
    """
  end

  @doc """
  Select component with dark theme styling.
  """
  attr :name, :string, required: true
  attr :options, :list, required: true
  attr :value, :any, default: nil
  attr :class, :string, default: ""
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <select
      name={@name}
      class={[
        "h-9 px-3 rounded-md text-sm font-medium transition-colors w-full",
        "bg-zinc-900 border border-zinc-800 text-zinc-100",
        "hover:border-zinc-700",
        "focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500",
        @class
      ]}
      {@rest}
    >
      <%= for {label, val} <- @options do %>
        <option value={val} selected={@value == val}><%= label %></option>
      <% end %>
    </select>
    """
  end

  @doc """
  Badge component for status indicators.
  """
  attr :variant, :atom, default: :neutral
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
      @variant == :success && "bg-emerald-500/20 text-emerald-400 border border-emerald-500/30",
      @variant == :warning && "bg-amber-500/20 text-amber-400 border border-amber-500/30",
      @variant == :error && "bg-red-500/20 text-red-400 border border-red-500/30",
      @variant == :info && "bg-blue-500/20 text-blue-400 border border-blue-500/30",
      @variant == :neutral && "bg-zinc-700/50 text-zinc-400 border border-zinc-700",
      @variant == :primary && "bg-indigo-500/20 text-indigo-400 border border-indigo-500/30",
      @class
    ]}>
      <%= render_slot(@inner_block) %>
    </span>
    """
  end

  @doc """
  Card component with dark theme.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["bg-zinc-900 border border-zinc-800 rounded-lg", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  @doc """
  Table wrapper component.
  """
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def table_wrapper(assigns) do
    ~H"""
    <div class={["bg-zinc-900 border border-zinc-800 rounded-lg overflow-hidden", @class]}>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
