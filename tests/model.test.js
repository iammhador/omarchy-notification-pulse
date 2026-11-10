// Run: node tests/model.test.js
const fs = require("fs"), path = require("path"), assert = require("assert")
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "")
const M = new Function(src + "; return { clean, parseRows, parseArchive, serialiseArchive, merge, pruneRemoved, unreadCount, filter, apps, dayBucket, relative, plain, decorate, brandFor, letterFor, sameRows, splitSender, senderLine, escapeMarkup, formatText, safeUrl, groupRows, noGroups, togglePin, isPinned, today, BRANDS }")()

const now = 1_800_000_000
const row = (key, ts, extra) => Object.assign({ key, ts, app: "Zen", summary: "Hi", body: "there" }, extra || {})

// Rows are validated and bounded.
assert.strictEqual(M.clean({ key: "bad key!", ts: 1 }), null)
assert.strictEqual(M.clean({ key: "ok", ts: 0 }), null)
assert.strictEqual(M.clean(row("a", 5, { summary: "x".repeat(5000) })).summary.length, 600)
assert.strictEqual(M.clean(row("a", 5, { urgency: 9 })).urgency, 1)
assert.strictEqual(M.clean(row("a", 5, { senderPid: -3 })).pid, 0)
assert.deepStrictEqual(M.parseRows("not json"), [])
assert.deepStrictEqual(M.parseRows('{"key":"a"}'), [])

// Markup-shaped input survives as inert text and can be neutralised.
const evil = M.clean(row("m", 5, { body: '<img src="https://example.invalid/t">' }))
assert.strictEqual(evil.body, '<img src="https://example.invalid/t">')
assert.ok(!/[<>]/.test(M.plain(evil.body)))

// Merge: newer wins, retention / clear / removed honoured, newest first, capped.
const opts = { now, retentionDays: 7, maxEntries: 3, clearedTs: 0, removed: {} }
let out = M.merge([row("a", now - 100, { summary: "old" })], [row("a", now - 100, { summary: "new" }), row("b", now - 50)], opts)
assert.deepStrictEqual(out.map(r => r.key), ["b", "a"])
assert.strictEqual(out[1].summary, "new")
out = M.merge([row("old", now - 8 * 86400)], [], opts)
assert.strictEqual(out.length, 0)
out = M.merge([], [row("a", now - 10), row("b", now - 1000)], Object.assign({}, opts, { clearedTs: now - 500 }))
assert.deepStrictEqual(out.map(r => r.key), ["a"])
out = M.merge([], [row("a", now - 10)], Object.assign({}, opts, { removed: { a: true } }))
assert.strictEqual(out.length, 0)
out = M.merge([], [1, 2, 3, 4, 5].map(i => row("k" + i, now - i)), opts)
assert.deepStrictEqual(out.map(r => r.key), ["k1", "k2", "k3"])

// Removed keys are forgotten once Omarchy's files drop them.
assert.deepStrictEqual(M.pruneRemoved({ a: true, b: true }, [row("a", 1)]), { a: true })

// Archive round-trips.
const state = { entries: [M.clean(row("a", now))], seenTs: 7, clearedTs: 3, removed: { z: true }, pinned: [] }
const back = M.parseArchive(M.serialiseArchive(state))
assert.deepStrictEqual(back, state)
assert.deepStrictEqual(M.parseArchive("[]"), { entries: [], seenTs: 0, clearedTs: 0, removed: {}, pinned: [] })

// Unread, search, app chips.
const list = [row("a", 30, { app: "Zen" }), row("b", 20, { app: "Slack", body: "Deploy done" }), row("c", 10, { app: "Zen" })]
assert.strictEqual(M.unreadCount(list, 15), 2)
assert.deepStrictEqual(M.filter(list, "deploy", "").map(r => r.key), ["b"])
assert.deepStrictEqual(M.filter(list, "", "Zen").map(r => r.key), ["a", "c"])
assert.deepStrictEqual(M.apps(list), [{ app: "Zen", count: 2 }, { app: "Slack", count: 1 }])

// Senders: the site behind a browser, by title, hostname, or native app.
let d = M.decorate(row("i", 1, { app: "Zen", source: "Zen", summary: "Instagram", body: "Sent a reel" }))
assert.deepStrictEqual([d.brand, d.name, d.via, d.title, d.text], ["instagram", "Instagram", "Zen", "", "Sent a reel"])
d = M.decorate(row("w", 1, { app: "Chromium", source: "web.whatsapp.com", summary: "Rahim", body: "hey" }))
assert.deepStrictEqual([d.brand, d.name, d.via, d.title], ["whatsapp", "WhatsApp", "Chromium", "Rahim"])
d = M.decorate(row("u", 1, { app: "Zen", source: "news.example.org", summary: "Breaking" }))
assert.deepStrictEqual([d.brand, d.name, d.via], ["", "news.example.org", "Zen"])
d = M.decorate(row("v", 1, { app: "vesktop", source: "vesktop", summary: "#general" }))
assert.deepStrictEqual([d.brand, d.name, d.via, d.title], ["discord", "Discord", "", "#general"])
d = M.decorate(row("n", 1, { app: "omasnap", source: "omasnap", summary: "Screenshot saved" }))
assert.deepStrictEqual([d.brand, d.name, d.via], ["", "omasnap", ""])
assert.strictEqual(M.brandFor(row("q", 1, { app: "Zen", summary: "Instagrammer weekly" })), null)
assert.strictEqual(M.brandFor(row("q", 1, { app: "Zen", source: "notinstagram.com", summary: "x1" })), null)
assert.strictEqual(M.decorate(row("t", 1, { app: "Zen", summary: "Facebook: Mim commented on your post" })).title, "Facebook: Mim commented on your post")
const zen = [row("a", 3, { summary: "Instagram" }), row("b", 2, { summary: "Instagram" }), row("c", 1, { summary: "Facebook" })]
assert.deepStrictEqual(M.apps(zen), [{ app: "Instagram", count: 2 }, { app: "Facebook", count: 1 }])
assert.deepStrictEqual(M.filter(zen, "", "Facebook").map(r => r.key), ["c"])

// Time labels.
assert.strictEqual(M.dayBucket(now, now), "today")
assert.strictEqual(M.dayBucket(now - 86400, now), "yesterday")
assert.strictEqual(M.dayBucket(now - 5 * 86400, now), "older")
assert.deepStrictEqual(M.relative(now - 30, now), { unit: "now", n: 0 })
assert.deepStrictEqual(M.relative(now - 300, now), { unit: "minutes", n: 5 })
assert.deepStrictEqual(M.relative(now - 7200, now), { unit: "hours", n: 2 })
assert.strictEqual(M.relative(now - 86400, now).unit, "clock")

// Letter tiles: only for browser rows with no known brand; stable per title.
d = M.decorate(row("l", 1, { app: "Zen", source: "Zen", summary: "Breaking News" }))
assert.strictEqual(d.letter, "B")
assert.strictEqual(d.letterColor, M.letterFor("Breaking News").color)
assert.strictEqual(M.decorate(row("l2", 1, { app: "Zen", summary: "Instagram" })).letter, "")
assert.strictEqual(M.decorate(row("l3", 1, { app: "omasnap", summary: "Saved" })).letter, "")
assert.strictEqual(M.letterFor("  ✓ 42 done").letter, "4")
assert.strictEqual(M.letterFor("").letter, "?")
assert.strictEqual(M.letterFor("প্রথম আলো").letter, "প")

// Sender split out of "name: message" on known sites only.
d = M.decorate(row("s1", 1, { app: "Zen", summary: "Instagram", body: "nocturn_a_l: https://www.facebook.com/share/r/19gw4G3Ye3/" }))
assert.deepStrictEqual([d.sender, d.text], ["nocturn_a_l", "https://www.facebook.com/share/r/19gw4G3Ye3/"])
d = M.decorate(row("s2", 1, { app: "Zen", summary: "Instagram", body: "Ashlm matro basai" }))
assert.deepStrictEqual([d.sender, d.text], ["", "Ashlm matro basai"])
d = M.decorate(row("s3", 1, { app: "Zen", summary: "Instagram", body: "https://example.com/x" }))
assert.strictEqual(d.sender, "")
d = M.decorate(row("s4", 1, { app: "Zen", summary: "Facebook", body: "Mim Rahman: see you at 8" }))
assert.deepStrictEqual([d.sender, d.text], ["Mim Rahman", "see you at 8"])
d = M.decorate(row("s5", 1, { app: "Zen", summary: "Rahim", body: "WhatsApp: hi" }))
assert.strictEqual(d.sender, "")   // a real title already says who it is
d = M.decorate(row("s6", 1, { app: "omasnap", summary: "Saved", body: "Note: file copied" }))
assert.strictEqual(d.sender, "")   // not a known site
assert.strictEqual(M.splitSender("this is way too many words to be a name: hi"), null)

// The inline "name: message" line escapes everything the sender wrote.
assert.strictEqual(M.senderLine("rafi.hasan", "hi"), "<b>rafi.hasan:</b> hi")
const hostile = M.senderLine('<img src="https://example.invalid/t">', '<a href="x">click</a> & <b>bold</b>\nline2')
assert.ok(!/<img|<a |<b>bold/.test(hostile))
assert.strictEqual(hostile.match(/<b>/g).length, 1)
assert.strictEqual(hostile.match(/<br>/g).length, 1)
assert.ok(hostile.includes("&lt;img src=&quot;https://example.invalid/t&quot;&gt;"))
assert.strictEqual(M.escapeMarkup("a & b"), "a &amp; b")

// Browser names: the common ones, and not apps that merely start with "web".
for (const b of ["Zen", "Firefox", "LibreWolf", "Floorp", "Mullvad Browser", "Tor Browser", "Chromium", "Google Chrome",
                 "Brave", "Brave Browser", "Vivaldi", "Thorium", "Microsoft Edge", "Opera", "Helium", "Web", "GNOME Web", "Falkon", "qutebrowser"])
  assert.strictEqual(M.decorate(row("b", 1, { app: b, summary: "Instagram" })).via, b, b)
for (const notB of ["Webex", "WebStorm", "Minecraft", "Thunderbird"])
  assert.strictEqual(M.decorate(row("n", 1, { app: notB, summary: "Hello" })).letter, "", notB)

// A re-read that finds nothing new must not count as a change.
const r1 = [row("a", 2), row("b", 1)]
assert.ok(M.sameRows(r1, r1.map(r => Object.assign({}, r))))
assert.ok(!M.sameRows(r1, [row("a", 2)]))
assert.ok(!M.sameRows(r1, [row("a", 2), row("b", 1, { body: "edited" })]))
const again = M.merge(r1, r1.map(r => Object.assign({}, r)), { now: 10, retentionDays: 7, maxEntries: 500, clearedTs: 0, removed: {} })
assert.ok(M.sameRows(again, r1))

// ---- v1.4 ---------------------------------------------------------------

// More sites, by title, hostname and native app.
const site = (extra) => M.decorate(row("z", 1, Object.assign({ app: "Zen", source: "Zen" }, extra)))
assert.strictEqual(site({ summary: "ChatGPT" }).brand, "chatgpt")
assert.strictEqual(site({ summary: "Claude" }).brand, "claude")
assert.strictEqual(site({ summary: "Gemini" }).brand, "gemini")
assert.strictEqual(site({ summary: "Substack" }).mono, "S")
assert.strictEqual(site({ summary: "Threads" }).name, "Threads")
assert.strictEqual(site({ summary: "Telegram" }).brand, "telegram")
assert.strictEqual(site({ summary: "Twitter" }).name, "X")
assert.strictEqual(site({ app: "Chromium", source: "chatgpt.com", summary: "Your answer is ready" }).brand, "chatgpt")
assert.strictEqual(site({ app: "Chromium", source: "meet.google.com", summary: "Rahim joined" }).brand, "gmeet")
assert.strictEqual(site({ app: "Chromium", source: "mail.google.com", summary: "New mail" }).brand, "gmail")
assert.strictEqual(site({ app: "Chromium", source: "www.google.com", summary: "Alert" }).brand, "google")
assert.strictEqual(site({ app: "Chromium", source: "someone.substack.com", summary: "New post" }).brand, "substack")
assert.strictEqual(site({ app: "Signal", source: "Signal", summary: "Mim" }).brand, "signal")
assert.strictEqual(site({ summary: "Messenger" }).brand, "messenger")
// Hostname beats title: a Gmail tab titled "Instagram" is still Gmail.
assert.strictEqual(site({ app: "Chromium", source: "mail.google.com", summary: "Instagram" }).brand, "gmail")
const ids = new Set(); for (const b of M.BRANDS) { assert.ok(!ids.has(b.id), b.id); ids.add(b.id); assert.ok(b.glyph || b.mono, b.id) }

// Links: http(s) only, clickable, escaped; trailing punctuation stays outside.
let f = M.formatText("see https://example.com/a?b=1&c=2. ok")
assert.strictEqual(f, 'see <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a>. ok')
f = M.formatText('javascript:alert(1) file:///etc/passwd <a href="https://evil">x</a>')
// The sender's own <a> stays escaped text; only real http(s) addresses link.
assert.ok(f.includes("&lt;a href=&quot;"), f)
for (const m of f.matchAll(/<a href="([^"]*)">/g)) assert.ok(/^https?:\/\//.test(m[1]), m[1])
assert.ok(!/href="(javascript|file)/i.test(f))
assert.strictEqual(M.safeUrl("https://ok.example/x"), "https://ok.example/x")
assert.strictEqual(M.safeUrl("javascript:alert(1)"), "")
assert.strictEqual(M.safeUrl('https://a.b/"onmouseover=x'), "")

// Search highlight: case-insensitive, escaped, colour validated.
f = M.formatText("Hello <World> hello", "hello", "#7AA2F7")
assert.strictEqual(f, '<font color="#7AA2F7"><b>Hello</b></font> &lt;World&gt; <font color="#7AA2F7"><b>hello</b></font>')
assert.strictEqual(M.formatText("a<b", "a", 'red" onclick="x'), "a&lt;b")
assert.strictEqual(M.formatText("x & y", "&", "#FFFFFF"), 'x <font color="#FFFFFF"><b>&amp;</b></font> y')
f = M.senderLine("rafi", "look https://x.example/p", "rafi", "#112233")
assert.strictEqual(f, '<b><font color="#112233"><b>rafi</b></font>:</b> look <a href="https://x.example/p">https://x.example/p</a>')

// Grouping: back-to-back, same site, same day; expand on demand.
const insta = (k, ts) => row(k, ts, { app: "Zen", summary: "Instagram" })
const day0 = new Date(2026, 10, 10, 12).getTime() / 1000
const seq = [insta("i1", day0), insta("i2", day0 - 60), insta("i3", day0 - 120), row("o1", day0 - 180, { app: "omasnap", summary: "Shot" }), insta("i4", day0 - 240)]
let g = M.groupRows(seq, {}, day0)
assert.deepStrictEqual(g.map(x => [x.row.key, x.groupSize, x.isChild]), [["i1", 3, false], ["o1", 1, false], ["i4", 1, false]])
g = M.groupRows(seq, { i1: true }, day0)
assert.deepStrictEqual(g.map(x => [x.row.key, x.isChild]), [["i1", false], ["i2", true], ["i3", true], ["o1", false], ["i4", false]])
g = M.groupRows([insta("a", day0), insta("b", day0 - 86400)], {}, day0)
assert.strictEqual(g.length, 2)   // never across days
assert.strictEqual(M.noGroups(seq).length, seq.length)

// Pins: toggle, cleaned, survive archive round-trip.
let pins = M.togglePin([], insta("p1", 5))
assert.ok(M.isPinned(pins, "p1"))
pins = M.togglePin(pins, insta("p2", 6))
assert.deepStrictEqual(pins.map(p => p.key), ["p2", "p1"])
assert.deepStrictEqual(M.togglePin(pins, insta("p1", 5)).map(p => p.key), ["p2"])
assert.deepStrictEqual(M.togglePin([], { key: "bad key", ts: 1 }), [])
const st2 = M.parseArchive(M.serialiseArchive({ entries: [], seenTs: 0, clearedTs: 0, removed: {}, pinned: pins }))
assert.deepStrictEqual(st2.pinned.map(p => p.key), ["p2", "p1"])

// Today summary.
const t = M.today([insta("a", day0), insta("b", day0 - 60), row("w", day0 - 90, { app: "Zen", summary: "WhatsApp" }), insta("old", day0 - 86400 * 2)], day0, 3)
assert.strictEqual(t.total, 3)
assert.deepStrictEqual(t.top.map(x => [x.name, x.count, x.color]), [["Instagram", 2, "#E1306C"], ["WhatsApp", 1, "#25D366"]])

console.log("ok: all model tests passed")
