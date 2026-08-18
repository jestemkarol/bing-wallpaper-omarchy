// Runs Model.js under node. Model.js is a QML JS resource with no exports, so
// it is evaluated into a scratch object here rather than required.

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const M = vm.createContext({})
vm.runInContext(source, M, { filename: "Model.js" })

let passed = 0
let failed = 0

function is(label, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log("  \x1b[32mok\x1b[0m   " + label)
    passed++
  } else {
    console.log("  \x1b[31mFAIL\x1b[0m " + label + "\n     expected " + e + ", got " + a)
    failed++
  }
}

console.log("Model.js")

// --- markets -----------------------------------------------------------------

is("exact locale match", M.marketForLocale("pl_PL"), "pl-PL")
is("strips a codeset suffix", M.marketForLocale("de_DE.UTF-8"), "de-DE")
is("falls back within a language", M.marketForLocale("de_AT"), "de-DE")
is("unknown language lands on en-US", M.marketForLocale("sw_KE"), "en-US")
is("empty locale lands on en-US", M.marketForLocale(""), "en-US")
is("auto defers to the locale", M.resolveMarket("auto", "ja_JP"), "ja-JP")
is("an explicit market wins", M.resolveMarket("fr-CA", "ja_JP"), "fr-CA")
is("a bogus market falls back", M.resolveMarket("xx-YY", "it_IT"), "it-IT")

// --- state parsing -----------------------------------------------------------

const raw = JSON.stringify({
  version: 1, market: "en-US", resolution: "UHD", keepDays: 30, fetchedAt: 1787000000,
  entries: [
    { date: "20260816", title: "Older", copyright: "A place (© Someone/Getty)", file: "/i/16.jpg", fullStartDate: "202608160700" },
    { date: "20260818", title: "Newest", copyright: "Another place (© Else/NPL)", file: "/i/18.jpg", fullStartDate: "202608180700" },
    { date: "20260817", title: "Middle", copyright: "", file: "/i/17.jpg", fullStartDate: "202608170700" }
  ]
})
const state = M.parseState(raw)

is("keeps every valid entry", state.entries.length, 3)
is("sorts newest first", state.entries.map(e => e.date), ["20260818", "20260817", "20260816"])
is("garbage parses to an empty library", M.parseState("{oops").entries, [])
is("a non-object parses to empty", M.parseState("42").entries, [])
is("entries without a file are dropped",
  M.parseState(JSON.stringify({ entries: [{ date: "20260818" }, { date: "20260817", file: "/i/17.jpg" }] })).entries.length, 1)
is("entries without a date are dropped",
  M.parseState(JSON.stringify({ entries: [{ file: "/i/x.jpg" }] })).entries.length, 0)
is("missing market defaults", M.parseState('{"entries":[]}').market, "en-US")

is("finds an entry by date", M.entryForDate(state, "20260817").title, "Middle")
is("missing date yields null", M.entryForDate(state, "19990101"), null)
is("finds an entry by file", M.indexOfFile(state.entries, "/i/16.jpg"), 2)

// --- navigation --------------------------------------------------------------

is("steps to the older day", M.step(state.entries, "20260818", 1).date, "20260817")
is("steps to the newer day", M.step(state.entries, "20260817", -1).date, "20260818")
is("wraps past the oldest", M.step(state.entries, "20260816", 1).date, "20260818")
is("wraps past the newest", M.step(state.entries, "20260818", -1).date, "20260816")
is("an unknown date starts at the newest", M.step(state.entries, "19990101", 1).date, "20260818")
is("an empty library has nowhere to step", M.step([], "20260818", 1), null)

// The dates are asserted rather than the indices: the whole point of these two
// helpers is that "older" means back in time whatever order the array is in, so
// an inversion has to fail here rather than only in the panel.
is("older than today is yesterday", M.olderEntry(state.entries, "20260818").date, "20260817")
is("newer than today wraps to the oldest", M.newerEntry(state.entries, "20260818").date, "20260816")
is("older than the oldest wraps to today", M.olderEntry(state.entries, "20260816").date, "20260818")
is("newer than the oldest is the day after it", M.newerEntry(state.entries, "20260816").date, "20260817")

// A full lap in each direction: three olders and three newers both come home.
const backwards = []
let walk = state.entries[0].date
for (let i = 0; i < 3; i++) { walk = M.olderEntry(state.entries, walk).date; backwards.push(walk) }
is("walking older visits every day and returns", backwards, ["20260817", "20260816", "20260818"])

const forwards = []
walk = state.entries[0].date
for (let i = 0; i < 3; i++) { walk = M.newerEntry(state.entries, walk).date; forwards.push(walk) }
is("walking newer visits every day and returns", forwards, ["20260816", "20260817", "20260818"])

const single = [state.entries[0]]
is("older on a single-image library stays put", M.olderEntry(single, "20260818").date, "20260818")
is("newer on a single-image library stays put", M.newerEntry(single, "20260818").date, "20260818")

is("older on an empty library is null", M.olderEntry([], "20260818"), null)
is("newer on an empty library is null", M.newerEntry([], "20260818"), null)

is("older from an unknown date starts at the newest",
  M.olderEntry(state.entries, "19990101").date, "20260818")
is("newer from an unknown date starts at the newest",
  M.newerEntry(state.entries, "19990101").date, "20260818")
is("older from no selection starts at the newest",
  M.olderEntry(state.entries, "").date, "20260818")

is("random avoids the current image", M.randomEntry(state.entries, "/i/18.jpg").file !== "/i/18.jpg", true)
is("random on a single-image library returns it", M.randomEntry([state.entries[0]], "/i/18.jpg").date, "20260818")
is("random on an empty library is null", M.randomEntry([], ""), null)

// --- scheduling --------------------------------------------------------------

const published = Date.UTC(2026, 7, 18, 7, 0, 0, 0)
const hour = 3600000

// Inside the last six hours the aim matters; before that the cap dominates,
// which is the point — a coarse poll keeps a suspended machine honest.
is("aims just past the next publication",
  M.nextCheckDelay(state, published + 19 * hour, 0), 5 * hour + 60000)
is("clamps a far-future target to six hours",
  M.nextCheckDelay(state, published, 0), 6 * hour)
is("clamps an overdue target to five minutes",
  M.nextCheckDelay(state, published + 48 * hour, 0), 5 * 60000)
is("no library means poll at the cap", M.nextCheckDelay(M.emptyState(), published, 0), 6 * hour)
is("an unparseable publish time polls at the cap",
  M.nextCheckDelay({ entries: [{ date: "20260818", file: "/i/18.jpg", fullStartDate: "nope" }] }, published, 0), 6 * hour)

is("first failure backs off a minute", M.nextCheckDelay(state, published, 1), 60000)
is("second failure backs off two", M.nextCheckDelay(state, published, 2), 120000)
is("backoff caps at half an hour", M.nextCheckDelay(state, published, 99), 1800000)

// --- formatting --------------------------------------------------------------

is("formats a date", M.formatDate("20260818"), "18 August 2026")
is("formats a short date", M.formatDateShort("20260801"), "1 Aug")
is("leaves a malformed date alone", M.formatDate("nonsense"), "nonsense")
is("rejects an impossible month", M.formatDate("20261318"), "20261318")

is("splits description from credit",
  M.splitCopyright("Aerial view of Palmanova, Italy (© Riccardo Saponi/Getty Images)"),
  { description: "Aerial view of Palmanova, Italy", credit: "© Riccardo Saponi/Getty Images" })
is("a line without a credit stays whole",
  M.splitCopyright("Just a description"), { description: "Just a description", credit: "" })
is("parentheses that are not a credit stay put",
  M.splitCopyright("A place (which is nice)").credit, "")
is("an empty line splits to empties", M.splitCopyright(""), { description: "", credit: "" })

is("describe prefers the title",
  M.describe(state.entries[0]).title, "Newest")
is("describe falls back to the description when there is no title",
  M.describe({ date: "20260818", title: "", copyright: "A place (© Someone)" }).title, "A place")
is("describe of nothing is empty", M.describe(null).title, "")

is("today is today", M.isToday("20260818", new Date(2026, 7, 18)), true)
is("yesterday is not", M.isToday("20260817", new Date(2026, 7, 18)), false)
is("single-digit days are zero-padded", M.isToday("20260801", new Date(2026, 7, 1)), true)


// --- settings ----------------------------------------------------------------

const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8"))
is("Model defaults match the manifest", M.DEFAULTS, manifest.barWidget.defaults)
is("every default has a schema entry",
  Object.keys(M.DEFAULTS).sort(),
  manifest.barWidget.schema.map(f => f.key).sort())
is("schema default values match Model defaults",
  manifest.barWidget.schema.every(f => JSON.stringify(f.defaultValue) === JSON.stringify(M.DEFAULTS[f.key])),
  true)

const ID = manifest.id
const barConfig = JSON.stringify({
  bar: { layout: { left: [{ id: "omarchy.menu" }], center: [], right: [{ id: ID, resolution: "1920x1080", notify: true }] } },
  plugins: []
})
is("reads settings off the bar entry", M.settingsFromShellConfig(barConfig, ID).resolution, "1920x1080")
is("unset keys fall back to defaults", M.settingsFromShellConfig(barConfig, ID).market, "auto")
is("booleans survive the round trip", M.settingsFromShellConfig(barConfig, ID).notify, true)

const headlessConfig = JSON.stringify({
  bar: { layout: { left: [], center: [], right: [] } },
  plugins: [{ id: ID, market: "pl-PL", keepDays: 7 }]
})
is("reads settings off a headless plugins[] entry",
  M.settingsFromShellConfig(headlessConfig, ID).market, "pl-PL")
is("integers survive the round trip",
  M.settingsFromShellConfig(headlessConfig, ID).keepDays, 7)

is("an absent entry yields defaults",
  M.settingsFromShellConfig('{"bar":{"layout":{"left":[]}},"plugins":[]}', ID), M.DEFAULTS)
is("unparseable config yields defaults", M.settingsFromShellConfig("{oops", ID), M.DEFAULTS)
is("an empty config yields defaults", M.settingsFromShellConfig("", ID), M.DEFAULTS)

is("string booleans are coerced",
  M.settingsFromShellConfig(JSON.stringify({ plugins: [{ id: ID, autoApply: "false" }] }), ID).autoApply, false)
is("keepDays is clamped low",
  M.settingsFromShellConfig(JSON.stringify({ plugins: [{ id: ID, keepDays: 0 }] }), ID).keepDays, 1)
is("keepDays is clamped high",
  M.settingsFromShellConfig(JSON.stringify({ plugins: [{ id: ID, keepDays: 99999 }] }), ID).keepDays, 365)
is("a nonsense keepDays falls back",
  M.settingsFromShellConfig(JSON.stringify({ plugins: [{ id: ID, keepDays: "soon" }] }), ID).keepDays, 30)

const base = M.normalizeSettings(null)
is("a notification toggle needs no refetch",
  M.settingsAffectLibrary(base, M.normalizeSettings({ notify: true })), false)
is("a market change needs a refetch",
  M.settingsAffectLibrary(base, M.normalizeSettings({ market: "de-DE" })), true)
is("a resolution change needs a refetch",
  M.settingsAffectLibrary(base, M.normalizeSettings({ resolution: "1366x768" })), true)
is("a retention change needs a refetch",
  M.settingsAffectLibrary(base, M.normalizeSettings({ keepDays: 5 })), true)
is("a missing side needs a refetch", M.settingsAffectLibrary(null, base), true)

console.log("")
console.log(passed + " passed, " + failed + " failed")
process.exit(failed === 0 ? 0 : 1)
