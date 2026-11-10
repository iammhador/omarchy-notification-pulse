.pragma library

// Notification Pulse — pure data logic, no QML. Tested by tests/model.test.js.
//
// Omarchy's notification service keeps closed notifications in
// ~/.local/state/omarchy/notifications/history.json for 24 hours (100 max) and
// the ones still on screen in live.json. This plugin reads both and folds them
// into its own longer-lived archive. Every row read from disk is untrusted:
// it is re-validated and bounded, and drawn either as plain text or as
// StyledText built here with every sender-written character escaped.

var KEY = /^[A-Za-z0-9_-]{1,120}$/
var MAX_FILE_CHARS = 4 * 1024 * 1024
var MAX_ROWS_PER_FILE = 2000
var MAX_REMOVED = 2000
var MAX_PINNED = 200
var LIMITS = { app: 120, appIcon: 200, glyph: 8, summary: 600, body: 4000, source: 200 }

function str(value, max) {
  var s = value === undefined || value === null ? "" : String(value)
  return s.length > max ? s.slice(0, max) : s
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

// One stored row, held to our own rules whatever wrote it.
function clean(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var key = String(raw.key || "")
  var ts = num(raw.ts)
  if (!KEY.test(key) || ts <= 0) return null
  var pid = Math.floor(num(raw.senderPid !== undefined ? raw.senderPid : raw.pid))
  var urgency = Math.floor(num(raw.urgency))
  return {
    key: key,
    app: str(raw.app, LIMITS.app),
    appIcon: str(raw.appIcon, LIMITS.appIcon),
    glyph: str(raw.glyph, LIMITS.glyph),
    summary: str(raw.summary, LIMITS.summary),
    body: str(raw.body, LIMITS.body),
    source: str(raw.source, LIMITS.source),
    urgency: urgency >= 0 && urgency <= 2 ? urgency : 1,
    pid: pid > 0 && pid < 4194305 ? pid : 0,
    ts: ts
  }
}

function parseJson(text) {
  var s = String(text || "")
  if (!s || s.length > MAX_FILE_CHARS) return null
  try { return JSON.parse(s) } catch (e) { return null }
}

function cleanRows(data, limit) {
  if (!Array.isArray(data)) return []
  var out = []
  for (var i = 0; i < data.length && out.length < limit; i++) {
    var row = clean(data[i])
    if (row) out.push(row)
  }
  return out
}

// history.json / live.json: an array of rows.
function parseRows(text) {
  return cleanRows(parseJson(text), MAX_ROWS_PER_FILE)
}

function emptyState() {
  return { entries: [], seenTs: 0, clearedTs: 0, removed: {}, pinned: [] }
}

// Our archive.json:
// { version, seenTs, clearedTs, removed: [keys], entries: [rows], pinned: [rows] }.
// Pinned rows are kept whole, so they outlive retention, the cap and Clear.
function parseArchive(text) {
  var data = parseJson(text)
  var state = emptyState()
  if (!data || typeof data !== "object" || Array.isArray(data)) return state
  state.seenTs = Math.max(0, num(data.seenTs))
  state.clearedTs = Math.max(0, num(data.clearedTs))
  if (Array.isArray(data.removed)) {
    for (var r = 0; r < data.removed.length && r < MAX_REMOVED; r++) {
      var k = String(data.removed[r] || "")
      if (KEY.test(k)) state.removed[k] = true
    }
  }
  state.entries = cleanRows(data.entries, MAX_ROWS_PER_FILE)
  state.pinned = cleanRows(data.pinned, MAX_PINNED)
  return state
}

function serialiseArchive(state) {
  return JSON.stringify({
    version: 2,
    seenTs: state.seenTs,
    clearedTs: state.clearedTs,
    removed: Object.keys(state.removed || {}),
    entries: state.entries,
    pinned: state.pinned || []
  })
}

// Fold rows from Omarchy's files into the archive. Newer data for a key wins,
// anything older than the retention window, cleared, or removed is dropped,
// and the result is newest first and capped.
function merge(archived, incoming, opts) {
  var now = num(opts.now)
  var cutoff = now - Math.max(1, num(opts.retentionDays)) * 86400
  var clearedTs = num(opts.clearedTs)
  var removed = opts.removed || {}
  var byKey = {}
  var lists = [archived || [], incoming || []]
  for (var l = 0; l < lists.length; l++) {
    for (var i = 0; i < lists[l].length; i++) {
      var row = lists[l][i]
      if (!row || row.ts <= cutoff || row.ts <= clearedTs || removed[row.key]) continue
      byKey[row.key] = row
    }
  }
  var out = []
  for (var key in byKey) out.push(byKey[key])
  out.sort(function(a, b) { return b.ts - a.ts })
  return out.slice(0, Math.max(1, Math.floor(num(opts.maxEntries)) || 500))
}

// Same rows in the same order, with the same content: nothing to redraw.
function sameRows(a, b) {
  if (a === b) return true
  if (!a || !b || a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    var x = a[i], y = b[i]
    if (x.key !== y.key || x.ts !== y.ts || x.summary !== y.summary || x.body !== y.body) return false
  }
  return true
}

// Removed keys only need remembering while Omarchy's own files still hold them.
function pruneRemoved(removed, sourceRows) {
  var present = {}
  for (var i = 0; i < sourceRows.length; i++) present[sourceRows[i].key] = true
  var out = {}
  for (var key in removed) if (present[key]) out[key] = true
  return out
}

// ------------------------------------------------------------ pins

function isPinned(pinned, key) {
  for (var i = 0; i < pinned.length; i++) if (pinned[i].key === key) return true
  return false
}

// Pin adds the row (newest pin first); pinning again unpins.
function togglePin(pinned, row) {
  if (isPinned(pinned, row.key)) return pinned.filter(function(p) { return p.key !== row.key })
  var c = clean(row)
  return c ? [c].concat(pinned).slice(0, MAX_PINNED) : pinned
}

function unreadCount(entries, seenTs) {
  var n = 0
  for (var i = 0; i < entries.length; i++) if (entries[i].ts > seenTs) n++
  return n
}

function matches(row, needle) {
  var q = String(needle || "").trim().toLowerCase()
  if (!q) return true
  var look = decorate(row)
  return (look.name + "\n" + row.app + "\n" + row.summary + "\n" + row.body + "\n" + row.source).toLowerCase().indexOf(q) >= 0
}

// `app` filters by display name: "Instagram", not the browser it came through.
function filter(entries, needle, app) {
  var out = []
  for (var i = 0; i < entries.length; i++) {
    var row = entries[i]
    if (app && decorate(row).name !== app) continue
    if (matches(row, needle)) out.push(row)
  }
  return out
}

// Senders by how many notifications they sent, for the filter tabs.
function apps(entries, limit) {
  var counts = {}
  for (var i = 0; i < entries.length; i++) {
    var name = decorate(entries[i]).name
    if (name) counts[name] = (counts[name] || 0) + 1
  }
  var out = []
  for (var app in counts) out.push({ app: app, count: counts[app] })
  out.sort(function(a, b) { return b.count - a.count || (a.app < b.app ? -1 : 1) })
  return out.slice(0, limit || 6)
}

// ------------------------------------------------------------ grouping
//
// Back-to-back notifications from the same site on the same day fold into
// one row: "Instagram · 6 messages". Searching shows every match unfolded.

function groupRows(rows, expanded, now) {
  var out = []
  var i = 0
  while (i < rows.length) {
    var head = rows[i], name = decorate(head).name, day = dayStart(head.ts)
    var j = i + 1
    while (j < rows.length && decorate(rows[j]).name === name && dayStart(rows[j].ts) === day) j++
    var size = j - i
    var open = size > 1 && !!(expanded && expanded[head.key])
    out.push({ row: head, groupKey: head.key, groupSize: size, isHead: true, isChild: false, open: open })
    if (open) for (var k = i + 1; k < j; k++)
      out.push({ row: rows[k], groupKey: head.key, groupSize: size, isHead: false, isChild: true, open: true })
    i = j
  }
  return out
}

function noGroups(rows) {
  return rows.map(function(r) { return { row: r, groupKey: r.key, groupSize: 1, isHead: true, isChild: false, open: false } })
}

// ------------------------------------------------------------ time

// Local midnight of the day a timestamp falls on, in seconds.
function dayStart(ts) {
  var d = new Date(ts * 1000)
  d.setHours(0, 0, 0, 0)
  return d.getTime() / 1000
}

// "today" | "yesterday" | "older": the QML side turns these into words.
function dayBucket(ts, now) {
  var diff = Math.round((dayStart(now) - dayStart(ts)) / 86400)
  if (diff <= 0) return "today"
  if (diff === 1) return "yesterday"
  return "older"
}

// { unit: "now" | "minutes" | "hours" | "clock", n } — words come from i18n.
function relative(ts, now) {
  var s = Math.max(0, now - ts)
  if (s < 60) return { unit: "now", n: 0 }
  if (s < 3600) return { unit: "minutes", n: Math.floor(s / 60) }
  if (s < 6 * 3600) return { unit: "hours", n: Math.floor(s / 3600) }
  return { unit: "clock", n: 0 }
}

// Today at a glance: how many, and the top senders with their colours.
function today(entries, now, limit) {
  var start = dayStart(now), counts = {}, colors = {}, total = 0
  for (var i = 0; i < entries.length; i++) {
    if (entries[i].ts < start) continue
    total++
    var look = decorate(entries[i])
    counts[look.name] = (counts[look.name] || 0) + 1
    if (!colors[look.name]) colors[look.name] = look.color || look.letterColor || ""
  }
  var top = []
  for (var name in counts) top.push({ name: name, count: counts[name], color: colors[name] })
  top.sort(function(a, b) { return b.count - a.count || (a.name < b.name ? -1 : 1) })
  return { total: total, top: top.slice(0, limit || 3) }
}

// ------------------------------------------------------------ text
//
// Rows are drawn as StyledText so links can be clicked and search matches
// lit. Only the tags built here are markup: <b>, <br>, <font color> and
// <a href> around an http(s) URL. Everything else is escaped.

function escapeMarkup(text) {
  return String(text || "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
    .replace(/\r?\n/g, "<br>")
}

var URL_RE = /\bhttps?:\/\/[^\s<>"'`]+/gi
var SAFE_URL = /^https?:\/\/[^\s<>"'`]{1,2040}$/i
var COLOR_RE = /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/

function safeUrl(url) {
  var s = String(url || "")
  return SAFE_URL.test(s) ? s : ""
}

// Escape a run of plain text, lighting up every case-insensitive match.
function lit(text, query, color) {
  var q = String(query || "").trim()
  if (!q || !COLOR_RE.test(color)) return escapeMarkup(text)
  var lower = text.toLowerCase(), needle = q.toLowerCase(), out = "", at = 0
  while (true) {
    var hit = lower.indexOf(needle, at)
    if (hit < 0) break
    out += escapeMarkup(text.slice(at, hit))
      + '<font color="' + color + '"><b>' + escapeMarkup(text.slice(hit, hit + needle.length)) + "</b></font>"
    at = hit + needle.length
  }
  return out + escapeMarkup(text.slice(at))
}

// Text → StyledText with clickable links and highlighted matches.
function formatText(text, query, color) {
  var s = String(text || ""), out = "", at = 0, m
  URL_RE.lastIndex = 0
  while ((m = URL_RE.exec(s)) !== null) {
    var url = m[0].replace(/[.,;:!?)\]}]+$/, "")
    out += lit(s.slice(at, m.index), query, color)
    var safe = safeUrl(url)
    out += safe ? '<a href="' + escapeMarkup(safe) + '">' + escapeMarkup(url) + "</a>" : escapeMarkup(url)
    at = m.index + url.length
    URL_RE.lastIndex = at
  }
  return out + lit(s.slice(at), query, color)
}

// "**name:** message", with the same link and highlight handling.
function senderLine(sender, message, query, color) {
  return "<b>" + lit(String(sender || ""), query, color) + ":</b> " + formatText(message, query, color)
}

// Neutralise anything that could read as markup, for sinks we don't own.
function plain(text) {
  return String(text || "").replace(/</g, "‹").replace(/>/g, "›")
}

// ------------------------------------------------------------ who sent it
//
// Browsers send web notifications under their own name ("Zen"), with the site
// only in the title ("Instagram") or, for web apps, as a hostname in `source`.
// Known sites and apps get their own name, logo (a Nerd Font glyph, or a bold
// letter where the font has no logo) and colour, all local: no favicon is
// ever fetched.

var BROWSER = /^(zen|firefox|librewolf|floorp|waterfox|mullvad browser|tor browser|chrom|google chrome|brave|vivaldi|thorium|cromite|edge|microsoft edge|helium|opera|epiphany|gnome web|web$|falkon|qutebrowser|min$)/i

function B(id, name, glyph, color, titles, hosts, apps, mono) {
  return { id: id, name: name, glyph: glyph, mono: mono || "", color: color, titles: titles, hosts: hosts, apps: apps }
}

// Order matters where names overlap: Messenger before Facebook, the Google
// products before plain Google. color "" means monochrome (drawn near-black).
var BRANDS = [
  // Messaging
  B("whatsapp", "WhatsApp", "\u{f05a3}", "#25D366", ["whatsapp"], ["whatsapp.com"], ["whatsapp", "zapzap", "whatsie"]),
  B("telegram", "Telegram", "\u{f2c6}", "#26A5E4", ["telegram"], ["telegram.org", "t.me"], ["telegram"]),
  B("messenger", "Messenger", "\u{f020e}", "#0084FF", ["messenger"], ["messenger.com"], ["messenger", "caprine"]),
  B("signal", "Signal", "", "#3A76F0", ["signal"], ["signal.org"], ["signal"], "S"),
  B("discord", "Discord", "\u{f066f}", "#5865F2", ["discord"], ["discord.com", "discord.gg"], ["discord", "vesktop", "webcord", "legcord"]),
  B("slack", "Slack", "\u{f04b1}", "#E01E5A", ["slack"], ["slack.com"], ["slack"]),
  B("teams", "Teams", "\u{f02bb}", "#6264A7", ["microsoft teams", "teams"], ["teams.microsoft.com", "teams.live.com"], ["teams", "microsoft teams"]),
  B("skype", "Skype", "\u{f04af}", "#00AFF0", ["skype"], ["skype.com"], ["skype"]),
  B("wechat", "WeChat", "\u{f0611}", "#07C160", ["wechat"], ["wechat.com"], ["wechat"]),
  B("viber", "Viber", "\u{ed38}", "#7360F2", ["viber"], ["viber.com"], ["viber"]),
  B("snapchat", "Snapchat", "\u{f04b6}", "#E8C400", ["snapchat"], ["snapchat.com"], ["snapchat"]),
  // Social
  B("instagram", "Instagram", "\u{f02fe}", "#E1306C", ["instagram"], ["instagram.com"], ["instagram"]),
  B("facebook", "Facebook", "\u{f020c}", "#1877F2", ["facebook"], ["facebook.com", "fb.com"], ["facebook"]),
  B("x", "X", "\u{f0544}", "", ["x", "twitter"], ["x.com", "twitter.com"], []),
  B("threads", "Threads", "", "", ["threads"], ["threads.net", "threads.com"], [], "@"),
  B("bluesky", "Bluesky", "\u{f1589}", "#1185FE", ["bluesky"], ["bsky.app"], ["bluesky"]),
  B("mastodon", "Mastodon", "\u{f0ad1}", "#6364FF", ["mastodon"], ["mastodon.social", "mastodon.online"], ["mastodon", "tuba", "tokodon"]),
  B("reddit", "Reddit", "\u{f044d}", "#FF4500", ["reddit"], ["reddit.com"], ["reddit"]),
  B("linkedin", "LinkedIn", "\u{f033b}", "#0A66C2", ["linkedin"], ["linkedin.com"], ["linkedin"]),
  B("tiktok", "TikTok", "", "", ["tiktok"], ["tiktok.com"], ["tiktok"], "T"),
  B("pinterest", "Pinterest", "\u{f0407}", "#E60023", ["pinterest"], ["pinterest.com"], ["pinterest"]),
  B("tumblr", "Tumblr", "\u{f173}", "#36465D", ["tumblr"], ["tumblr.com"], ["tumblr"]),
  B("quora", "Quora", "\u{f0d29}", "#B92B27", ["quora"], ["quora.com"], ["quora"]),
  B("substack", "Substack", "", "#FF6719", ["substack"], ["substack.com"], ["substack"], "S"),
  B("medium", "Medium", "\u{f23a}", "", ["medium"], ["medium.com"], ["medium"]),
  // AI
  B("chatgpt", "ChatGPT", "\u{ec81}", "#10A37F", ["chatgpt", "openai"], ["chatgpt.com", "chat.openai.com", "openai.com"], ["chatgpt"]),
  B("claude", "Claude", "\u{ec82}", "#D97757", ["claude"], ["claude.ai", "claude.com", "anthropic.com"], ["claude"]),
  B("gemini", "Gemini", "\u{ec10}", "#4285F4", ["gemini", "google gemini"], ["gemini.google.com"], ["gemini"]),
  B("copilot", "Copilot", "\u{ec1e}", "#0078D4", ["copilot", "microsoft copilot"], ["copilot.microsoft.com"], ["copilot"]),
  B("perplexity", "Perplexity", "", "#20808D", ["perplexity"], ["perplexity.ai"], ["perplexity"], "P"),
  // Video & music
  B("youtube", "YouTube", "\u{f05c3}", "#FF0033", ["youtube"], ["youtube.com", "youtu.be"], ["youtube", "freetube"]),
  B("twitch", "Twitch", "\u{f0543}", "#9146FF", ["twitch"], ["twitch.tv"], ["twitch"]),
  B("netflix", "Netflix", "\u{f0746}", "#E50914", ["netflix"], ["netflix.com"], ["netflix"]),
  B("spotify", "Spotify", "\u{f04c7}", "#1DB954", ["spotify"], ["spotify.com"], ["spotify"]),
  B("soundcloud", "SoundCloud", "\u{f04c0}", "#FF5500", ["soundcloud"], ["soundcloud.com"], ["soundcloud"]),
  B("patreon", "Patreon", "\u{f0882}", "", ["patreon"], ["patreon.com"], ["patreon"]),
  // Mail, calendar, meetings
  B("gmail", "Gmail", "\u{f02ab}", "#EA4335", ["gmail"], ["mail.google.com"], ["gmail"]),
  B("gcalendar", "Google Calendar", "\u{f073}", "#1A73E8", ["google calendar"], ["calendar.google.com"], []),
  B("gmeet", "Google Meet", "\u{f03d}", "#00897B", ["google meet"], ["meet.google.com"], []),
  B("gdrive", "Google Drive", "\u{f02b6}", "#1FA463", ["google drive"], ["drive.google.com", "docs.google.com"], []),
  B("outlook", "Outlook", "\u{f0d22}", "#0078D4", ["outlook"], ["outlook.live.com", "outlook.office.com", "outlook.com"], ["outlook"]),
  B("zoom", "Zoom", "\u{f03d}", "#2D8CFF", ["zoom"], ["zoom.us"], ["zoom"]),
  B("google", "Google", "\u{f02ad}", "#4285F4", ["google"], ["google.com"], []),
  // Work & dev
  B("notion", "Notion", "\u{e848}", "", ["notion"], ["notion.so", "notion.com"], ["notion"]),
  B("figma", "Figma", "\u{ef47}", "#F24E1E", ["figma"], ["figma.com"], ["figma"]),
  B("trello", "Trello", "\u{f0532}", "#0079BF", ["trello"], ["trello.com"], ["trello"]),
  B("jira", "Jira", "\u{f0303}", "#0052CC", ["jira"], ["atlassian.net", "atlassian.com"], ["jira"]),
  B("github", "GitHub", "\u{f02a4}", "", ["github"], ["github.com"], ["github"]),
  B("gitlab", "GitLab", "\u{f0ba0}", "#FC6D26", ["gitlab"], ["gitlab.com"], ["gitlab"]),
  B("stackoverflow", "Stack Overflow", "\u{f04cc}", "#F48024", ["stack overflow"], ["stackoverflow.com"], []),
  B("dropbox", "Dropbox", "\u{f01e3}", "#0061FF", ["dropbox"], ["dropbox.com"], ["dropbox"]),
  // Shopping & money
  B("amazon", "Amazon", "\u{f270}", "#FF9900", ["amazon"], ["amazon.com"], []),
  B("paypal", "PayPal", "\u{f1ed}", "#003087", ["paypal"], ["paypal.com"], []),
  B("steam", "Steam", "\u{f04d3}", "#1B2838", ["steam"], ["steampowered.com", "steamcommunity.com"], ["steam"])
]

function hostOf(value) {
  var s = String(value || "").trim().toLowerCase().replace(/^[a-z]+:\/\//, "").split(/[\/?#:]/)[0]
  return /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(s) ? s : ""
}

function hostMatches(host, suffix) {
  return host === suffix || host.slice(-(suffix.length + 1)) === "." + suffix
}

// "Instagram", "Instagram (3)", "Instagram: new reel"; not "Instagrammer".
function titleMatches(title, name) {
  if (title === name) return true
  if (title.indexOf(name) !== 0) return false
  return /^[^a-z0-9]/i.test(title.charAt(name.length))
}

// Hostnames first (exact), then native app names, then titles.
function brandFor(row) {
  var host = hostOf(row.source)
  var title = String(row.summary || "").trim().toLowerCase()
  var app = String(row.app || "").trim().toLowerCase()
  var i, k, b
  if (host) for (i = 0; i < BRANDS.length; i++) {
    b = BRANDS[i]
    for (k = 0; k < b.hosts.length; k++) if (hostMatches(host, b.hosts[k])) return b
  }
  if (app) for (i = 0; i < BRANDS.length; i++) {
    b = BRANDS[i]
    for (k = 0; k < b.apps.length; k++) if (app.indexOf(b.apps[k]) === 0) return b
  }
  if (title) for (i = 0; i < BRANDS.length; i++) {
    b = BRANDS[i]
    for (k = 0; k < b.titles.length; k++) if (titleMatches(title, b.titles[k])) return b
  }
  return null
}

// Colours that read clearly on a white tile.
var LETTER_COLORS = ["#E53935", "#D81B60", "#8E24AA", "#5E35B1", "#3949AB", "#1E88E5",
                     "#00897B", "#43A047", "#F4511E", "#6D4C41", "#546E7A", "#C0CA33"]

// A stable letter + colour for a sender we have no logo for.
function letterFor(text) {
  var s = String(text || "").trim()
  // Letters and digits, including Latin, Greek, Cyrillic, Arabic, Devanagari,
  // Bangla, Kana, CJK and Hangul; never a symbol or emoji.
  var m = s.match(/[A-Za-z0-9À-ɏͰ-ӿ؀-ۿऀ-৿぀-ヿ一-鿿가-힯]/)
  var letter = m ? m[0].toUpperCase() : "?"
  var h = 0
  for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0
  return { letter: letter, color: LETTER_COLORS[h % LETTER_COLORS.length] }
}

// "nocturn_a_l: https://…" or "Mim Rahman: hi" → { sender, message }.
// A sender is a handle or up to four words, followed by ": " — so a URL's
// "https://" never reads as one.
var SENDER = /^([A-Za-z0-9._À-ɏঀ-৿-]{1,30}(?: [A-Za-z0-9._À-ɏঀ-৿-]{1,30}){0,3}): +([\s\S]+)$/

function splitSender(text) {
  var m = String(text || "").match(SENDER)
  if (!m || /^(https?|ftp|mailto)$/i.test(m[1])) return null
  return { sender: m[1], message: m[2] }
}

// What a row shows: { brand, name, via, glyph, mono, color, title, sender,
// text, browser, letter, letterColor }. A title that only repeats the
// sender's name is dropped, so the message itself leads.
function decorate(row) {
  var brand = brandFor(row)
  var host = hostOf(row.source)
  var app = String(row.app || "")
  var browser = BROWSER.test(app)
  var name = brand ? brand.name : (host ? host.replace(/^www\./, "") : (app || String(row.source || "")))
  var via = (brand || host) && app && app.toLowerCase() !== name.toLowerCase() && browser ? app : ""
  var title = String(row.summary || "")
  if (brand && titleMatches(title.trim().toLowerCase(), brand.name.toLowerCase()) && title.trim().length <= brand.name.length + 6) title = ""
  var out = {
    brand: brand ? brand.id : "",
    name: name || "Notification",
    via: via,
    glyph: brand ? brand.glyph : "",
    mono: brand ? brand.mono : "",
    color: brand ? brand.color : "",
    title: title,
    sender: "",
    text: String(row.body || ""),
    browser: browser,
    letter: "",
    letterColor: ""
  }
  // Social sites that only say "Instagram" sometimes name the sender in the text.
  if (brand && title === "") {
    var split = splitSender(out.text)
    if (split) { out.sender = split.sender; out.text = split.message }
  }
  if (!brand && browser) {
    var l = letterFor(host || row.summary || app)
    out.letter = l.letter
    out.letterColor = l.color
  }
  return out
}
