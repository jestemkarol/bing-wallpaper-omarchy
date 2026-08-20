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

// The credit link is feed data and the panel opens it. These pin that only a plain
// http(s) URL survives, so nothing that could be read as shell syntax reaches the
// opener even if the panel is ever wired back to a command line.
const REAL_CREDIT =
  "https://www.bing.com/search?q=Palmanova+Italy&form=hpcapt&filters=HpDate%3a%2220260818_0700%22"
is("a real Bing credit link is kept", M.externalUrl(REAL_CREDIT), REAL_CREDIT)
is("http is allowed", M.externalUrl("http://example.test/a"), "http://example.test/a")
is("an uppercase scheme is allowed",
  M.externalUrl("HTTPS://example.test/a"), "HTTPS://example.test/a")
is("surrounding whitespace is trimmed",
  M.externalUrl("  https://example.test/a  "), "https://example.test/a")

is("command substitution is refused", M.externalUrl("https://x.test/$(id)"), "")
is("backticks are refused", M.externalUrl("https://x.test/`id`"), "")
is("a double quote is refused", M.externalUrl('https://x.test/a"b'), "")
is("a single quote is refused", M.externalUrl("https://x.test/a'b"), "")
is("a backslash is refused", M.externalUrl("https://x.test/a\\b"), "")
is("a semicolon payload is refused", M.externalUrl("https://x.test/a\nrm -rf /"), "")
is("an embedded space is refused", M.externalUrl("https://x.test/a b"), "")
is("a control character is refused", M.externalUrl("https://x.test/a\u0007b"), "")
is("the javascript scheme is refused", M.externalUrl("javascript:alert(1)"), "")
is("the file scheme is refused", M.externalUrl("file:///etc/passwd"), "")
is("the data scheme is refused", M.externalUrl("data:text/html,<script>"), "")
is("a scheme-relative url is refused", M.externalUrl("//example.test/a"), "")
is("a bare word is refused", M.externalUrl("not a url"), "")
is("an empty link is refused", M.externalUrl(""), "")
is("a null link is refused", M.externalUrl(null), "")
is("an undefined link is refused", M.externalUrl(undefined), "")

// --- what reaches the notification argv ------------------------------------

// omarchy-notification-send has no -- separator and reads the first argument
// not starting with a dash as the description, so a title beginning with one
// is taken as an option and the notification is lost.
is("an ordinary title is passed through",
  M.notificationText({ title: "Palmanova, Italy", date: "18 August 2026" }),
  "Palmanova, Italy")
is("a leading dash is kept out of option shape",
  M.notificationText({ title: "-40 degrees in Oymyakon", date: "x" }),
  " -40 degrees in Oymyakon")
is("a double dash is kept out too",
  M.notificationText({ title: "--exec", date: "x" }), " --exec")
is("the date is the fallback",
  M.notificationText({ title: "", date: "18 August 2026" }), "18 August 2026")
is("a dashed date fallback is handled",
  M.notificationText({ title: "", date: "-x" }), " -x")
is("an empty description is empty",
  M.notificationText({ title: "", date: "" }), "")
is("a missing description is empty", M.notificationText(null), "")

// --- what reaches a Text element -------------------------------------------

// Titles and copyright are rendered by Text items and by the bar tooltip, and
// QML's default AutoText mode turns anything that looks like markup into a
// rich-text document. An <img> in a feed title was fetched on render, with no
// click involved. Our Text items pin PlainText; the shared tooltip cannot, so
// the value is defused before it leaves the model.
is("an image tag cannot survive",
  M.displayText('<img src="http://tracker.test/x.png">'),
  'img src="http://tracker.test/x.png"')
is("a bare angle bracket goes",
  M.displayText("a < b > c"), "a  b  c")
is("a script tag cannot survive",
  M.displayText("<script>fetch('http://x.test')</script>"),
  "scriptfetch('http://x.test')/script")
is("an html document cannot survive",
  M.displayText("<!DOCTYPE html><html><body>"), "!DOCTYPE htmlhtmlbody")
// An entity fires the same heuristic with no bracket in sight, so the token is
// broken while an ordinary ampersand is left alone.
is("a named entity is broken",
  M.displayText("Sunrise &lt;over the bay"), "Sunrise &ltover the bay")
is("a numeric entity is broken", M.displayText("&#60;script"), "&#60script")
is("a hex entity is broken", M.displayText("&#x3c;script"), "&#x3cscript")
is("an ampersand is left alone",
  M.displayText("Black & white"), "Black & white")
is("an ampersand before a word is left alone",
  M.displayText("AT&T Building"), "AT&T Building")
is("a non-entity is left alone",
  M.displayText("x&notanentityatall"), "x&notanentityatall")
is("a zero-width space is stripped", M.displayText("a\u200bb"), "ab")
is("a soft hyphen is stripped", M.displayText("a\u00adb"), "ab")
is("a right-to-left mark is stripped", M.displayText("a\u200fb"), "ab")
is("an accented title is left alone",
  M.displayText("Île de Ré, Nouvelle-Aquitaine"), "Île de Ré, Nouvelle-Aquitaine")
is("a cjk title is left alone", M.displayText("東京の夜景"), "東京の夜景")
is("a bidi override is stripped",
  M.displayText("photo by \u202eevil\u202c"), "photo by evil")
is("a control character is stripped",
  M.displayText("a\u0000b\u001fc"), "abc")
is("a newline survives as text",
  M.displayText("line one\nline two"), "line one\nline two")
is("an empty value stays empty", M.displayText(""), "")
is("a null value stays empty", M.displayText(null), "")
is("an undefined value stays empty", M.displayText(undefined), "")

// describe() is the single boundary the panel and the bar both read through,
// so the defusing has to happen there rather than at each call site.
const marked = M.describe({
  title: '<img src="http://tracker.test/t.png">Palmanova',
  copyright: '<b>Aerial view</b> (© <img src="http://tracker.test/c.png">Photographer)',
  date: "20260818"
})
is("a marked-up title is defused", marked.title,
  'img src="http://tracker.test/t.png"Palmanova')
is("a marked-up description is defused", marked.description, "bAerial view/b")
is("a marked-up credit is defused", marked.credit,
  '© img src="http://tracker.test/c.png"Photographer')
is("no angle bracket reaches the title", /[<>]/.test(marked.title), false)
is("no angle bracket reaches the description", /[<>]/.test(marked.description), false)
is("no angle bracket reaches the credit", /[<>]/.test(marked.credit), false)

// The ordinary case still has to come through intact.
const plain = M.describe({
  title: "Palmanova, Italy",
  copyright: "Palmanova, Italy (© Amazing Aerial Agency/Offset)",
  date: "20260818"
})
is("a normal title is unchanged", plain.title, "Palmanova, Italy")
is("a normal description is unchanged", plain.description, "Palmanova, Italy")
is("a normal credit is unchanged", plain.credit,
  "© Amazing Aerial Agency/Offset")
is("a normal date is unchanged", plain.date, "18 August 2026")

// formatDate hands back anything that is not eight digits untouched. The feed
// can no longer supply one, but a state.json written before that check existed
// still can, and the date reaches AutoText consumers of its own.
const staleDate = M.describe({ title: "t", copyright: "", date: '<img src="http://t.test/d.png">' })
is("a marked-up date is defused", staleDate.date, 'img src="http://t.test/d.png"')
is("no angle bracket reaches the date", /[<>]/.test(staleDate.date), false)

console.log("")
console.log(passed + " passed, " + failed + " failed")
process.exit(failed === 0 ? 0 : 1)
