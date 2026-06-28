import { Controller } from "@hotwired/stimulus"

// Near-real-time, read-only refresh for the Production Control Center.
// Periodically fetches the authoritative status fragment and swaps it in place
// without a full-page reload. On failure it shows a non-blocking yellow warning
// and keeps the last-known (stale) cards rather than panicking red.
export default class extends Controller {
  static targets = ["content", "timestamp", "health", "dot"]
  static values = {
    url: String,
    interval: { type: Number, default: 8000 }
  }

  connect() {
    this.failures = 0
    this.start()
  }

  disconnect() {
    this.stop()
  }

  start() {
    this.timer = setInterval(() => this.refresh(), this.intervalValue)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
  }

  // Manual "Refresh now" button.
  refreshNow(event) {
    if (event) event.preventDefault()
    this.refresh()
  }

  async refresh() {
    this.setHealth("refreshing", "Refreshing…")
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/html" },
        credentials: "same-origin"
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const html = await response.text()
      if (this.hasContentTarget) this.contentTarget.innerHTML = html
      this.failures = 0
      this.markRefreshed()
      this.setHealth("ok", `Auto-refreshing every ${Math.round(this.intervalValue / 1000)}s`)
    } catch (error) {
      this.failures += 1
      this.setHealth("error", `Refresh failed (${this.failures}) — showing last known data`)
    }
  }

  markRefreshed() {
    if (!this.hasTimestampTarget) return
    const now = new Date()
    this.timestampTarget.textContent = now.toLocaleTimeString()
  }

  setHealth(state, message) {
    if (this.hasHealthTarget) this.healthTarget.textContent = message
    if (!this.hasDotTarget) return
    const colors = {
      ok: "bg-green-500",
      refreshing: "bg-blue-400",
      error: "bg-yellow-400"
    }
    this.dotTarget.className = `h-2 w-2 rounded-full ${colors[state] || "bg-gray-500"}`
  }
}
