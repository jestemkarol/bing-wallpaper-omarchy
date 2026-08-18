// Pure helpers shared by Service.qml and Panel.qml. Nothing in here touches
// QML types, the filesystem, or the network, so the scheduling and formatting
// rules can be tested outside a running shell (see test/model.js).

// The markets Bing publishes a daily image for. Anything else is accepted by
// the API but tends to fall back to en-US, so the settings list stops here.
var MARKETS = [
  "en-US", "en-GB", "en-AU", "en-CA", "en-IN",
  "de-DE", "fr-FR", "fr-CA", "es-ES", "it-IT",
  "pt-BR", "nl-NL", "pl-PL", "ja-JP", "zh-CN", "ko-KR"
]

var DEFAULT_MARKET = "en-US"

var MONTHS = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]

// Never poll harder than this, and never let a scheduling mistake park the
// timer for a whole day — six hours also serves as the coarse catch-up after
// the machine wakes from suspend.
var MIN_CHECK_MS = 5 * 60 * 1000
var MAX_CHECK_MS = 6 * 60 * 60 * 1000
var BACKOFF_MS = [60000, 120000, 300000, 900000, 1800000]

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

// Qt reports locales as "pl_PL" / "en_US.UTF-8"; Bing wants "pl-PL". An exact
// match wins, then the first market sharing the language, then en-US.
function marketForLocale(localeName) {
  var name = trimmed(localeName).split(".")[0].replace("_", "-")
  if (!name) return DEFAULT_MARKET

  var parts = name.split("-")
  var language = parts[0].toLowerCase()
  var region = parts.length > 1 ? parts[1].toUpperCase() : ""
  var candidate = region ? language + "-" + region : ""

  for (var i = 0; i < MARKETS.length; i++) {
    if (MARKETS[i] === candidate) return MARKETS[i]
  }
  for (var j = 0; j < MARKETS.length; j++) {
    if (MARKETS[j].split("-")[0] === language) return MARKETS[j]
  }
  return DEFAULT_MARKET
}

// "auto" defers to the system locale; anything unrecognized falls back rather
// than sending the sync script a market it will refuse.
function resolveMarket(setting, localeName) {
  var value = trimmed(setting)
  if (!value || value === "auto") return marketForLocale(localeName)
  for (var i = 0; i < MARKETS.length; i++) {
    if (MARKETS[i] === value) return value
  }
  return marketForLocale(localeName)
}

function emptyState() {
  return { version: 1, market: DEFAULT_MARKET, resolution: "UHD", keepDays: 30, fetchedAt: 0, entries: [] }
}

// state.json is written by bing-wallpaper-sync. A half-written or hand-edited
// file must degrade to "no library yet" rather than break the panel.
function parseState(raw) {
  var empty = emptyState()
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return empty
    if (!Array.isArray(data.entries)) return empty

    var entries = []
    for (var i = 0; i < data.entries.length; i++) {
      var entry = data.entries[i]
      if (!entry || typeof entry !== "object") continue
      if (!trimmed(entry.date) || !trimmed(entry.file)) continue
      entries.push({
        date: trimmed(entry.date),
        fullStartDate: trimmed(entry.fullStartDate),
        endDate: trimmed(entry.endDate),
        title: trimmed(entry.title),
        copyright: trimmed(entry.copyright),
        copyrightLink: trimmed(entry.copyrightLink),
        market: trimmed(entry.market) || empty.market,
        resolution: trimmed(entry.resolution) || empty.resolution,
        url: trimmed(entry.url),
        file: trimmed(entry.file)
      })
    }
    entries.sort(function (a, b) { return a.date < b.date ? 1 : (a.date > b.date ? -1 : 0) })

    return {
      version: Number(data.version) || 1,
      market: trimmed(data.market) || empty.market,
      resolution: trimmed(data.resolution) || empty.resolution,
      keepDays: Number(data.keepDays) || empty.keepDays,
      fetchedAt: Number(data.fetchedAt) || 0,
      entries: entries
    }
  } catch (e) {
    return empty
  }
}

function indexOfDate(entries, date) {
  var key = trimmed(date)
  if (!key || !Array.isArray(entries)) return -1
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].date === key) return i
  }
  return -1
}

function indexOfFile(entries, file) {
  var key = trimmed(file)
  if (!key || !Array.isArray(entries)) return -1
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].file === key) return i
  }
  return -1
}

function entryForDate(state, date) {
  var entries = state && Array.isArray(state.entries) ? state.entries : []
  var index = indexOfDate(entries, date)
  return index === -1 ? null : entries[index]
}

// Entries are newest first, so "older" walks forward. Both directions wrap so
// the panel's arrows never dead-end.
function step(entries, date, direction) {
  if (!Array.isArray(entries) || entries.length === 0) return null
  var index = indexOfDate(entries, date)
  if (index === -1) return entries[0]
  var next = (index + direction + entries.length) % entries.length
  return entries[next]
}

function randomEntry(entries, excludeFile) {
  if (!Array.isArray(entries) || entries.length === 0) return null
  if (entries.length === 1) return entries[0]

  var pool = []
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].file !== trimmed(excludeFile)) pool.push(entries[i])
  }
  if (pool.length === 0) pool = entries
  return pool[Math.floor(Math.random() * pool.length)]
}

// "202608180700" is the UTC instant Bing published the image. Returns null for
// anything that isn't that exact shape, so callers fall back to polling.
function parseFullStartDate(value) {
  var text = trimmed(value)
  if (!/^\d{12}$/.test(text)) return null
  var year = Number(text.slice(0, 4))
  var month = Number(text.slice(4, 6))
  var day = Number(text.slice(6, 8))
  var hour = Number(text.slice(8, 10))
  var minute = Number(text.slice(10, 12))
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59) return null
  return Date.UTC(year, month - 1, day, hour, minute, 0, 0)
}

// How long to wait before asking Bing again. A successful fetch aims just past
// the next publication (24h after the current one); a failure backs off. The
// clamp is what makes this safe: a stale or missing fullStartDate degrades to a
// six-hour poll instead of a timer that never fires.
function nextCheckDelay(state, nowMs, failureCount) {
  var failures = Math.max(0, Math.floor(Number(failureCount) || 0))
  if (failures > 0) {
    return BACKOFF_MS[Math.min(failures - 1, BACKOFF_MS.length - 1)]
  }

  var now = Number(nowMs) || 0
  var entries = state && Array.isArray(state.entries) ? state.entries : []
  var published = entries.length > 0 ? parseFullStartDate(entries[0].fullStartDate) : null
  if (published === null) return MAX_CHECK_MS

  // A minute of slack past the rollover: asking at the exact second reliably
  // returns yesterday's image and costs a whole extra cycle.
  var target = published + 24 * 60 * 60 * 1000 + 60000
  return Math.max(MIN_CHECK_MS, Math.min(MAX_CHECK_MS, target - now))
}

// "20260818" -> "18 August 2026". Unparseable dates come back untouched so a
// hand-edited state file shows something rather than "Invalid Date".
function formatDate(date) {
  var text = trimmed(date)
  if (!/^\d{8}$/.test(text)) return text
  var month = Number(text.slice(4, 6))
  if (month < 1 || month > 12) return text
  return String(Number(text.slice(6, 8))) + " " + MONTHS[month - 1] + " " + text.slice(0, 4)
}

// "20260818" -> "18 Aug"; the compact form the day navigation shows.
function formatDateShort(date) {
  var text = trimmed(date)
  if (!/^\d{8}$/.test(text)) return text
  var month = Number(text.slice(4, 6))
  if (month < 1 || month > 12) return text
  return String(Number(text.slice(6, 8))) + " " + MONTHS[month - 1].slice(0, 3)
}

function isToday(date, nowDate) {
  // Duck-typed rather than `instanceof Date`: the caller's Date may come from
  // a different JS realm (a QML component, a test harness), where instanceof
  // silently fails and today's comparison would quietly use the wall clock.
  var now = nowDate && typeof nowDate.getFullYear === "function" ? nowDate : new Date()
  var year = String(now.getFullYear())
  var month = String(now.getMonth() + 1)
  var day = String(now.getDate())
  if (month.length < 2) month = "0" + month
  if (day.length < 2) day = "0" + day
  return trimmed(date) === year + month + day
}

// Bing packs place and photographer into one string:
//   "Aerial view of Palmanova, ... Italy (© Riccardo Saponi/Getty Images)"
// The panel shows the description and the credit on separate lines.
function splitCopyright(copyright) {
  var text = trimmed(copyright)
  if (!text) return { description: "", credit: "" }

  var match = text.match(/^([\s\S]*?)\s*\((©[\s\S]*)\)\s*$/)
  if (!match) return { description: text, credit: "" }
  return { description: trimmed(match[1]), credit: trimmed(match[2]) }
}

function describe(entry) {
  if (!entry) return { title: "", description: "", credit: "", date: "" }
  var parts = splitCopyright(entry.copyright)
  return {
    title: trimmed(entry.title) || parts.description,
    description: parts.description,
    credit: parts.credit,
    date: formatDate(entry.date)
  }
}

// ---------------------------------------------------------------- settings

// Mirrors manifest.json's barWidget.defaults — test/model.js asserts the two
// stay identical, so the manifest remains the documented source of truth while
// the service can still resolve settings before anything is injected into it.
var DEFAULTS = {
  market: "auto",
  resolution: "UHD",
  autoApply: true,
  reapplyAfterThemeChange: true,
  randomFromLibrary: false,
  keepDays: 30,
  notify: false
}

function bool(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

function clampInt(value, minimum, maximum, fallback) {
  var n = Math.floor(Number(value))
  if (!isFinite(n)) return fallback
  return Math.max(minimum, Math.min(maximum, n))
}

// Coerces whatever shell.json holds into the shapes the service relies on. A
// hand-edited config is the normal case here, not an exotic one.
function normalizeSettings(raw) {
  var source = raw && typeof raw === "object" ? raw : {}
  return {
    market: trimmed(source.market) || DEFAULTS.market,
    resolution: trimmed(source.resolution) || DEFAULTS.resolution,
    autoApply: bool(source.autoApply, DEFAULTS.autoApply),
    reapplyAfterThemeChange: bool(source.reapplyAfterThemeChange, DEFAULTS.reapplyAfterThemeChange),
    randomFromLibrary: bool(source.randomFromLibrary, DEFAULTS.randomFromLibrary),
    keepDays: clampInt(source.keepDays, 1, 365, DEFAULTS.keepDays),
    notify: bool(source.notify, DEFAULTS.notify)
  }
}

// The service gets no settings injected — shell.qml hands service plugins only
// the shell object — so it reads its own shell.json entry. The entry lives in
// bar.layout.{left,center,right} when the widget is on the bar, or in the
// top-level plugins[] array when it runs headless.
function settingsFromShellConfig(raw, pluginId) {
  var id = trimmed(pluginId)
  try {
    var config = JSON.parse(String(raw || ""))
    if (!config || typeof config !== "object") return normalizeSettings(null)

    var sections = ["left", "center", "right"]
    if (config.bar && config.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var entries = config.bar.layout[sections[s]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++) {
          if (entries[i] && trimmed(entries[i].id) === id) return normalizeSettings(entries[i])
        }
      }
    }

    if (Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && trimmed(config.plugins[j].id) === id) return normalizeSettings(config.plugins[j])
      }
    }
  } catch (e) {
    // fall through to defaults
  }
  return normalizeSettings(null)
}

// Two settings objects only differ in a way that warrants a refetch when they
// change what lands on disk. Toggling notifications should not redownload the
// whole library.
function settingsAffectLibrary(a, b) {
  if (!a || !b) return true
  return a.market !== b.market || a.resolution !== b.resolution || a.keepDays !== b.keepDays
}
