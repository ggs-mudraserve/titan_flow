// Phoenix LiveView setup
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Hooks
let Hooks = {}

// Infinite scroll hook
Hooks.InfiniteScroll = {
    mounted() {
        this.loading = false
        this.debounceTimer = null

        this.observer = new IntersectionObserver(entries => {
            const entry = entries[0]
            if (entry.isIntersecting && !this.loading) {
                // Debounce to prevent rapid triggers
                if (this.debounceTimer) clearTimeout(this.debounceTimer)
                this.debounceTimer = setTimeout(() => {
                    this.loading = true
                    const event = this.el.dataset.event
                    this.pushEvent(event, {})
                }, 100)
            }
        }, { rootMargin: '100px' })  // Trigger slightly before reaching bottom

        // Create a sentinel element at the bottom
        this.sentinel = document.createElement("div")
        this.sentinel.style.height = "1px"
        this.sentinel.id = "infinite-scroll-sentinel"
        this.el.appendChild(this.sentinel)
        this.observer.observe(this.sentinel)
    },
    updated() {
        // After LiveView updates the DOM, ensure sentinel is at the end
        // and reset loading state to allow new loads
        this.loading = false
        if (this.sentinel && this.sentinel.parentNode === this.el) {
            // Re-append to ensure it's at the end
            this.el.appendChild(this.sentinel)
        } else if (this.sentinel) {
            // Sentinel was orphaned, re-attach
            this.el.appendChild(this.sentinel)
            this.observer.observe(this.sentinel)
        }
    },
    destroyed() {
        if (this.debounceTimer) clearTimeout(this.debounceTimer)
        this.observer.disconnect()
    }
}

// Auto-resize textarea hook
Hooks.AutoResize = {
    mounted() {
        this.el.addEventListener("input", () => {
            this.el.style.height = "auto"
            this.el.style.height = (this.el.scrollHeight) + "px"
        })
    }
}

// Phone select hook - bypasses form phx-change to push event directly
Hooks.PhoneSelect = {
    mounted() {
        this.el.addEventListener("change", (e) => {
            const senderId = this.el.dataset.senderId
            const phoneId = this.el.value
            console.log("PhoneSelect change:", senderId, phoneId)
            this.pushEvent("select_phone", { "sender-id": senderId, "phone-id": phoneId })
        })
    }
}

let liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: csrfToken },
    hooks: Hooks
})

// Connect if there are any LiveViews on the page
liveSocket.connect()

// Expose liveSocket on window for debugging
window.liveSocket = liveSocket
