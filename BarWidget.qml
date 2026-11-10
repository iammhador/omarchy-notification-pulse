// Notification Pulse — a notification inbox for the Omarchy bar.
//
// Bar:   a bell with an unread badge that swings and ripples in the sender's
//        colour when something arrives. Left click opens the inbox, right
//        click toggles Do Not Disturb, middle click marks everything read.
// Inbox: every notification from the last N days (Omarchy itself keeps only
//        24 hours), grouped by day and by sender, searchable with highlighted
//        matches, filterable by site, with clickable links, pins and a
//        today-at-a-glance strip. Fully keyboard driven.
//
// Data: reads Omarchy's own notification store (history.json, live.json,
// quiet.json) read-only, and folds it into a private archive at
// ~/.local/state/notification-pulse/archive.json (0600). Nothing is sent
// anywhere; no network access.

import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.iammhador.notification-pulse"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- settings

  // `omarchy bar set` stores plain strings, so accept "false" / "0" too.
  function flag(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "string") return !/^(false|0|no|off)$/i.test(v.trim())
    return !!v
  }
  function bounded(name, fallback, lo, hi) {
    var n = Math.floor(Number(setting(name, fallback)))
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : fallback
  }

  readonly property int retentionDays: bounded("retentionDays", 7, 1, 90)
  readonly property int maxEntries: bounded("maxEntries", 500, 50, 2000)
  readonly property bool showBadge: flag("showBadge", true)
  readonly property bool pulseOnNew: flag("pulse", true)
  readonly property bool groupSenders: flag("groupSenders", true)
  readonly property bool showToday: flag("showToday", true)
  // Unknown sites in a browser: "app" shows the browser's icon, "letter" a letter tile.
  readonly property string unknownIcon: String(setting("unknownIcon", "letter")) === "app" ? "app" : "letter"

  // ---------------------------------------------------------------- state

  readonly property string omarchyDir: Quickshell.env("HOME") + "/.local/state/omarchy/notifications"
  readonly property string archiveDir: Quickshell.env("HOME") + "/.local/state/notification-pulse"

  property var entries: []
  property var pinned: []
  property real seenTs: 0
  property real clearedTs: 0
  property var removed: ({})
  property var historyRows: []
  property var liveRows: []
  property bool storeReady: false
  property bool archiveLoaded: false
  property string lastSaved: ""
  property bool dnd: false

  property bool popupOpen: false
  property string query: ""
  property string appFilter: ""
  property var expanded: ({})
  property int selectedIndex: -1
  property real now: Date.now() / 1000

  readonly property int unread: Model.unreadCount(entries, seenTs)
  // Pinned rows are usually in `entries` too; count each notification once.
  readonly property var allRows: {
    var keys = {}
    for (var i = 0; i < pinned.length; i++) keys[pinned[i].key] = true
    return pinned.concat(entries.filter(function(r) { return !keys[r.key] }))
  }
  readonly property var topApps: Model.apps(allRows, 15)
  readonly property var todayInfo: { now; return Model.today(entries, now, 3) }

  // Shape contract for shell summon/hide/toggle routing.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  onPopupOpenChanged: {
    if (popupOpen) {
      now = Date.now() / 1000
      query = ""
      appFilter = ""
      selectedIndex = -1
      if (panel.loadedSearch) panel.loadedSearch.text = ""
      rebuild(true)
    } else {
      markSeen()
    }
  }
  onQueryChanged: { selectedIndex = -1; rebuild(true) }
  onAppFilterChanged: {
    selectedIndex = -1
    rebuild(true)
    if (tabStrip) Qt.callLater(tabStrip.reveal)
  }

  function cycleFilter(dir) {
    var names = [""].concat(topApps.map(function(a) { return a.app }))
    var at = Math.max(0, names.indexOf(appFilter))
    appFilter = names[(at + dir + names.length) % names.length]
  }
  // New data keeps your scroll position; only opening, searching and
  // switching tabs go back to the top.
  onEntriesChanged: if (popupOpen) rebuild(false)
  onPinnedChanged: if (popupOpen) rebuild(false)
  onRetentionDaysChanged: ingest()
  onMaxEntriesChanged: ingest()
  onUnknownIconChanged: if (popupOpen) rebuild(false)
  onGroupSendersChanged: if (popupOpen) rebuild(false)

  // ---------------------------------------------------------------- archive

  function ingest() {
    if (!archiveLoaded) return
    now = Date.now() / 1000
    var source = historyRows.concat(liveRows)
    var keep = Model.pruneRemoved(removed, source)
    var merged = Model.merge(entries, source, {
      now: now, retentionDays: retentionDays, maxEntries: maxEntries,
      clearedTs: clearedTs, removed: keep
    })
    // The periodic re-read usually finds nothing new; leave the list alone then.
    if (!Model.sameRows(merged, entries)) entries = merged
    removed = keep
    notice()
    save()
  }

  function save() {
    if (!archiveLoaded) return
    var text = Model.serialiseArchive({ entries: entries, seenTs: seenTs, clearedTs: clearedTs, removed: removed, pinned: pinned })
    if (text === lastSaved) return
    lastSaved = text
    archiveFile.setText(text)
  }

  // Our own writes echo back through the watcher; another bar (one per
  // monitor) writing is adopted, so badges agree across screens.
  function loadArchive(text) {
    var raw = String(text || "")
    if (archiveLoaded && raw === lastSaved) return
    var state = Model.parseArchive(raw)
    entries = state.entries
    pinned = state.pinned
    seenTs = state.seenTs
    clearedTs = state.clearedTs
    removed = state.removed
    lastSaved = raw
    if (!archiveLoaded) pulseArm.start()
    archiveLoaded = true
    ingest()
  }

  function markSeen() {
    var newest = entries.length ? entries[0].ts : 0
    if (newest > seenTs) {
      seenTs = newest
      save()
    }
  }

  // Pins survive Clear.
  function clearAll() {
    clearedTs = Date.now() / 1000
    seenTs = clearedTs
    removed = ({})
    entries = []
    save()
  }

  function rowByKey(key) {
    var lists = [pinned, entries]
    for (var l = 0; l < lists.length; l++)
      for (var i = 0; i < lists[l].length; i++) if (lists[l][i].key === key) return lists[l][i]
    return null
  }

  function removeEntry(key) {
    var next = Object.assign({}, removed)
    next[key] = true
    removed = next
    pinned = pinned.filter(function(row) { return row.key !== key })
    entries = entries.filter(function(row) { return row.key !== key })
    save()
  }

  function togglePin(key) {
    var row = rowByKey(key)
    if (!row) return
    pinned = Model.togglePin(pinned, row)
    save()
  }

  function toggleGroup(groupKey) {
    var next = Object.assign({}, expanded)
    if (next[groupKey]) delete next[groupKey]
    else next[groupKey] = true
    expanded = next
    rebuild(false)
  }

  // Private directory and file, created before anything writes them.
  Process {
    id: storePrepare
    running: true
    command: ["bash", "-c",
      "umask 077\n" +
      "mkdir -p -- \"$1\" && chmod 700 -- \"$1\" || exit 1\n" +
      "[ -e \"$1/archive.json\" ] || printf '{}' > \"$1/archive.json\"\n" +
      "chmod 600 -- \"$1/archive.json\"",
      "--", root.archiveDir]
    onExited: function(code) { root.storeReady = code === 0 }
  }

  FileView {
    id: archiveFile
    path: root.storeReady ? root.archiveDir + "/archive.json" : ""
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadArchive(text())
    onLoadFailed: root.loadArchive("")
  }

  FileView {
    path: root.omarchyDir + "/history.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.historyRows = Model.parseRows(text()); root.ingest() }
  }

  FileView {
    path: root.omarchyDir + "/live.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.liveRows = Model.parseRows(text()); root.ingest() }
  }

  FileView {
    path: root.omarchyDir + "/quiet.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.dnd = JSON.parse(String(text() || "{}")).dnd === true } catch (e) { root.dnd = false }
    }
  }

  // Atomic replaces can slip past a file watcher; a cheap re-read covers it.
  Timer {
    interval: root.popupOpen ? 2000 : 15000
    running: true
    repeat: true
    onTriggered: {
      root.now = Date.now() / 1000
      root.ingest()
    }
  }

  // ---------------------------------------------------------------- pulse
  //
  // The bell swings and a ring ripples out in the colour of whoever just
  // arrived. Startup and the first few seconds after it (files still
  // loading) never pulse.

  property real lastPulseTs: 0
  property bool pulseReady: false
  property color pulseColor: accent

  Timer { id: pulseArm; interval: 3000; onTriggered: root.pulseReady = true }

  function notice() {
    var newest = entries.length ? entries[0] : null
    if (!newest || newest.ts <= lastPulseTs) return
    lastPulseTs = newest.ts
    if (!pulseReady || !pulseOnNew || dnd || popupOpen) return
    pulseColor = markOf(Model.decorate(newest))
    pulseAnim.restart()
  }

  function markOf(look) {
    if (look.color) return look.color
    if (look.letterColor && unknownIcon === "letter") return look.letterColor
    return accent
  }

  // ---------------------------------------------------------------- actions

  function toggleDnd() {
    Quickshell.execDetached(["omarchy-toggle-notification-silencing"])
  }

  function copyRow(row) {
    var text = (row.title ? row.title + "\n" : "") + (row.sender ? row.sender + ": " : "") + (row.text || "")
    Quickshell.execDetached(["wl-copy", "--", text])
  }

  // Only http(s) links, handed to the browser as an argument, never a shell.
  function openLink(link) {
    var url = Model.safeUrl(link)
    if (!url) return
    Quickshell.execDetached(["xdg-open", url])
    close()
  }

  // Jump to the window that sent it: by pid first, then by app name.
  function focusApp(row) {
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    var byPid = null, byName = null
    var names = [String(row.source || "").toLowerCase(), String(row.app || "").toLowerCase()]
    for (var i = 0; i < list.length; i++) {
      var ipc = list[i].lastIpcObject
      if (!ipc) continue
      var order = Number(ipc.focusHistoryID !== undefined ? ipc.focusHistoryID : 9999)
      if (row.pid && Number(ipc.pid) === row.pid) {
        if (!byPid || order < byPid.order) byPid = { address: String(ipc.address || ""), order: order }
      }
      var cls = String(ipc["class"] || "").toLowerCase()
      for (var n = 0; n < names.length; n++) {
        if (names[n] && cls && (cls.indexOf(names[n]) >= 0 || names[n].indexOf(cls) >= 0)) {
          if (!byName || order < byName.order) byName = { address: String(ipc.address || ""), order: order }
        }
      }
    }
    var win = byPid || byName
    if (!win || !/^0x[0-9a-f]+$/i.test(win.address)) return false
    Hyprland.dispatch('hl.dsp.focus({window = hl.get_window("address:' + win.address + '")})')
    close()
    return true
  }

  // ---------------------------------------------------------------- keyboard

  function select(i) {
    if (rowsModel.count === 0) { selectedIndex = -1; return }
    selectedIndex = Math.max(-1, Math.min(rowsModel.count - 1, i))
    if (selectedIndex >= 0) list.positionViewAtIndex(selectedIndex, ListView.Contain)
    else list.positionViewAtBeginning()
  }

  function selectedRow() {
    return selectedIndex >= 0 && selectedIndex < rowsModel.count ? rowsModel.get(selectedIndex) : null
  }

  // Returns true when the key was ours.
  function handleKey(event, field) {
    var row = selectedRow()
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    switch (event.key) {
    case Qt.Key_Down: select(selectedIndex + 1); return true
    case Qt.Key_Up: select(selectedIndex - 1); return true
    case Qt.Key_PageDown: select(selectedIndex + 6); return true
    case Qt.Key_PageUp: select(selectedIndex - 6); return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
      var target = row || (rowsModel.count > 0 ? rowsModel.get(0) : null)
      if (target) root.focusApp(target)
      return true
    case Qt.Key_Tab: cycleFilter(1); return true
    case Qt.Key_Backtab: cycleFilter(-1); return true
    case Qt.Key_Escape:
      if (selectedIndex >= 0) select(-1)
      else if (field.text.length > 0) { field.text = ""; query = "" }
      else close()
      return true
    }
    if (!row) return false
    if (event.key === Qt.Key_Delete) {
      var at = selectedIndex
      removeEntry(row.key)
      Qt.callLater(function() { select(Math.min(at, rowsModel.count - 1)) })
      return true
    }
    if (ctrl && event.key === Qt.Key_P) { togglePin(row.key); return true }
    if (ctrl && event.key === Qt.Key_C && field.selectedText === "") { copyRow(row); return true }
    if ((event.key === Qt.Key_Right || event.key === Qt.Key_Left) && row.groupSize > 1) {
      var opening = event.key === Qt.Key_Right
      if (opening !== !!expanded[row.groupKey]) {
        var headAt = selectedIndex
        if (!opening) for (var i = selectedIndex; i >= 0; i--) if (rowsModel.get(i).key === row.groupKey) { headAt = i; break }
        toggleGroup(row.groupKey)
        Qt.callLater(function() { select(headAt) })
      }
      return true
    }
    return false
  }

  // ---------------------------------------------------------------- view model

  ListModel { id: rowsModel }

  function sectionLabel(ts) {
    var bucket = Model.dayBucket(ts, now)
    if (bucket === "today") return strings.t("day.today")
    if (bucket === "yesterday") return strings.t("day.yesterday")
    return Qt.locale(Commons.I18n.formatLocale).toString(new Date(ts * 1000), "dddd, d MMMM")
  }

  function timeLabel(ts, tick) {
    var rel = Model.relative(ts, tick)
    if (rel.unit === "now") return strings.t("time.now")
    if (rel.unit === "minutes") return strings.tn("time.minutes", rel.n).arg(Commons.I18n.formatNumber(rel.n))
    if (rel.unit === "hours") return strings.tn("time.hours", rel.n).arg(Commons.I18n.formatNumber(rel.n))
    var loc = Qt.locale(Commons.I18n.formatLocale)
    return loc.toString(new Date(ts * 1000), loc.timeFormat(Locale.ShortFormat))
  }

  function hexOf(c) {
    function h(v) { var s = Math.round(v * 255).toString(16); return s.length < 2 ? "0" + s : s }
    return "#" + h(c.r) + h(c.g) + h(c.b)
  }

  function modelRow(r, extra) {
    var look = Model.decorate(r)
    var q = query.trim(), hl = hexOf(accent)
    var primary = look.title !== "" ? look.title : look.text
    var secondary = look.title !== "" ? look.text : ""
    var out = {
      key: r.key, app: r.app, appIcon: r.appIcon, glyph: r.glyph, source: r.source,
      urgency: r.urgency, pid: r.pid, ts: r.ts, unread: r.ts > seenTs,
      name: look.name, via: look.via, brandGlyph: look.glyph, brandMono: look.mono, brandColor: look.color,
      title: look.title, sender: look.sender, text: look.text, letter: look.letter, letterColor: look.letterColor,
      primaryText: look.sender !== "" ? Model.senderLine(look.sender, primary, q, hl) : Model.formatText(primary, q, hl),
      secondaryText: Model.formatText(secondary, q, hl),
      hasPrimary: primary !== "" || look.sender !== "",
      hasSecondary: secondary !== "",
      pinned: false, day: "", groupKey: r.key, groupSize: 1, isChild: false, open: false
    }
    for (var k in extra) out[k] = extra[k]
    return out
  }

  function rebuild(toTop) {
    var keepY = list.contentY
    var pinnedKeys = {}
    for (var p = 0; p < pinned.length; p++) pinnedKeys[pinned[p].key] = true
    rowsModel.clear()

    var pins = Model.filter(pinned, query, appFilter)
    for (var i = 0; i < pins.length; i++)
      rowsModel.append(modelRow(pins[i], { pinned: true, day: strings.t("day.pinned") }))

    var rows = Model.filter(entries, query, appFilter).filter(function(r) { return !pinnedKeys[r.key] })
    var items = query.trim() !== "" || !groupSenders ? Model.noGroups(rows) : Model.groupRows(rows, expanded, now)
    for (var j = 0; j < items.length; j++) {
      var it = items[j]
      rowsModel.append(modelRow(it.row, {
        day: sectionLabel(it.row.ts), groupKey: it.groupKey, groupSize: it.groupSize,
        isChild: it.isChild, open: it.open
      }))
    }
    if (selectedIndex >= rowsModel.count) selectedIndex = rowsModel.count - 1
    if (toTop) Qt.callLater(function() { list.positionViewAtBeginning() })
    else Qt.callLater(function() {
      list.contentY = Math.max(list.originY, Math.min(keepY, list.originY + list.contentHeight - list.height))
    })
  }

  function iconSource(name) {
    var value = String(name || "")
    if (!value || value.indexOf("/") >= 0 || value.indexOf(":") >= 0) return ""
    return Quickshell.iconPath(value, true) || ""
  }

  // ---------------------------------------------------------------- ipc

  IpcHandler {
    target: "notification-pulse"
    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function clear(): void { root.clearAll() }
    function markRead(): void { root.markSeen() }
    function unread(): int { return root.unread }
    function isOpen(): bool { return root.popupOpen }
    // Open the inbox with a search already typed.
    function search(text: string): void {
      root.open()
      var q = String(text || "").slice(0, 200)
      root.query = q
      if (panel.loadedSearch) panel.loadedSearch.text = q
    }
    function pulse(): void { root.pulseColor = root.accent; pulseAnim.restart() }
  }

  // ---------------------------------------------------------------- colors

  readonly property color fg: Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.55)
  readonly property color accent: Commons.Color.accent
  readonly property color urgentColor: Commons.Color.urgent
  readonly property color line: Style.normalBorderFor(fg, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color subtle: Qt.alpha(fg, 0.06)
  // Barely-there corners, the same everywhere.
  readonly property int radius: Math.max(2, Math.round(Style.space(4)))

  // ================================================================ BAR

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Ripple ring behind the bell.
  Rectangle {
    id: ring
    anchors.centerIn: button
    width: Style.space(20); height: width
    radius: width / 2
    color: "transparent"
    border.width: Math.max(1, Style.space(2))
    border.color: root.pulseColor
    opacity: 0
    scale: 0.6
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.dnd ? "\u{f009b}" : (root.unread > 0 ? "\u{f116b}" : "\u{f009a}")
    slotSize: Style.bar.statusSlot
    foreground: flash.running ? root.pulseColor : (root.bar ? root.bar.barForeground : root.fg)
    tooltipText: root.popupOpen ? "" : (root.dnd ? strings.t("tooltip.dnd")
      : (root.unread > 0 ? strings.tn("tooltip.unread", root.unread).arg(Commons.I18n.formatNumber(root.unread))
                         : strings.t("tooltip.none")))

    transform: Rotation { id: swing; origin.x: button.width / 2; origin.y: button.height * 0.28; angle: 0 }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleDnd()
      else if (b === Qt.MiddleButton) root.markSeen()
      else root.toggle()
    }

    Rectangle {
      id: badge
      visible: root.showBadge && root.unread > 0 && !root.dnd
      readonly property string label: root.unread > 99 ? "99+" : Commons.I18n.formatNumber(root.unread)
      height: Math.round(Style.font.caption * 1.25)
      width: Math.max(height, badgeText.implicitWidth + Style.space(6))
      radius: height / 2
      color: flash.running ? root.pulseColor : root.accent
      x: Math.round(parent.width / 2 - Style.space(1))
      y: Math.round(parent.height / 2 - height - Style.space(1))

      Text {
        id: badgeText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: badge.label
        color: Commons.Color.background
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.9)
        font.bold: true
      }
    }
  }

  // Keeps the bell and badge tinted for the length of the pulse.
  Timer { id: flash; interval: Style.duration(1100) > 0 ? 1100 : 0 }

  ParallelAnimation {
    id: pulseAnim
    onStarted: if (flash.interval > 0) flash.restart()
    SequentialAnimation {
      NumberAnimation { target: swing; property: "angle"; to: -18; duration: Style.duration(90); easing.type: Easing.OutCubic }
      NumberAnimation { target: swing; property: "angle"; to: 14; duration: Style.duration(120); easing.type: Easing.InOutSine }
      NumberAnimation { target: swing; property: "angle"; to: -9; duration: Style.duration(120); easing.type: Easing.InOutSine }
      NumberAnimation { target: swing; property: "angle"; to: 5; duration: Style.duration(110); easing.type: Easing.InOutSine }
      NumberAnimation { target: swing; property: "angle"; to: 0; duration: Style.duration(120); easing.type: Easing.OutCubic }
    }
    SequentialAnimation {
      PropertyAction { target: ring; property: "scale"; value: 0.6 }
      PropertyAction { target: ring; property: "opacity"; value: 0.9 }
      ParallelAnimation {
        NumberAnimation { target: ring; property: "scale"; to: 1.7; duration: Style.duration(750); easing.type: Easing.OutCubic }
        NumberAnimation { target: ring; property: "opacity"; to: 0; duration: Style.duration(750); easing.type: Easing.OutCubic }
      }
    }
  }

  // ================================================================ INBOX
  //
  // Quiet by design: no box around each notification, just whitespace and a
  // soft hover. One small corner radius everywhere.

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: search
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.cappedContentHeight(Style.space(600))

    readonly property var loadedSearch: search

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(14)

      // ---- header ---------------------------------------------------------
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        z: 2

        Text {
          textFormat: Text.PlainText
          text: strings.t("panel.title")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Rectangle {
          visible: root.unread > 0
          Layout.leftMargin: Style.space(4)
          implicitWidth: newText.implicitWidth + Style.space(12)
          implicitHeight: newText.implicitHeight + Style.space(4)
          radius: root.radius
          color: Qt.alpha(root.accent, 0.16)
          Text {
            id: newText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: strings.tn("panel.new", root.unread).arg(Commons.I18n.formatNumber(root.unread))
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        Item { Layout.fillWidth: true }

        IconButton {
          glyph: root.dnd ? "\u{f009b}" : "\u{f009a}"
          tint: root.dnd ? root.accent : root.dim
          on: root.dnd
          hint: root.dnd ? strings.t("dnd.on") : strings.t("dnd.off")
          onClicked: root.toggleDnd()
        }
        IconButton {
          glyph: "\u{f0139}"
          enabled: root.unread > 0
          hint: strings.t("read.all")
          onClicked: root.markSeen()
        }
        IconButton {
          glyph: "\u{f0a7a}"
          enabled: root.entries.length > 0
          // Two deliberate clicks: the first turns it into a red "Clear all?"
          // button; a second click within the first 0.6 s (a double-click)
          // is ignored, so it can't clear by accident.
          tint: confirmTimer.running ? root.urgentColor : root.dim
          on: confirmTimer.running
          label: confirmTimer.running ? strings.t("clear.confirm") : ""
          hint: confirmTimer.running ? "" : strings.t("clear.label")
          property real armedAt: 0
          onClicked: {
            if (!confirmTimer.running) {
              armedAt = Date.now()
              confirmTimer.restart()
            } else if (Date.now() - armedAt >= 600) {
              confirmTimer.stop()
              root.clearAll()
            }
          }
          Timer { id: confirmTimer; interval: 4000 }
        }
      }

      // ---- today at a glance ----------------------------------------------
      Column {
        Layout.fillWidth: true
        Layout.topMargin: -Style.space(6)
        spacing: Style.space(7)
        visible: root.showToday && root.todayInfo.total > 0

        // One thin bar, split by sender colour.
        Row {
          width: parent.width
          height: Style.space(4)
          spacing: Style.space(2)
          readonly property int gaps: Math.max(0, todayBars.count)
          Repeater {
            id: todayBars
            model: root.todayInfo.top
            Rectangle {
              required property var modelData
              height: parent.height
              radius: height / 2
              width: Math.max(height, (parent.width - parent.spacing * parent.gaps) * modelData.count / root.todayInfo.total)
              color: modelData.color !== "" ? modelData.color : root.fg
            }
          }
          Rectangle {
            readonly property int rest: root.todayInfo.total - root.todayInfo.top.reduce(function(s, t) { return s + t.count }, 0)
            visible: rest > 0
            height: parent.height
            radius: height / 2
            width: Math.max(height, (parent.width - parent.spacing * parent.gaps) * rest / Math.max(1, root.todayInfo.total))
            color: Qt.alpha(root.fg, 0.18)
          }
        }

        Flow {
          width: parent.width
          spacing: Style.space(12)
          Text {
            textFormat: Text.PlainText
            text: strings.tn("today.count", root.todayInfo.total).arg(Commons.I18n.formatNumber(root.todayInfo.total))
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Repeater {
            model: root.todayInfo.top
            Row {
              required property var modelData
              spacing: Style.space(5)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(6); height: width; radius: width / 2
                color: parent.modelData.color !== "" ? parent.modelData.color : root.fg
              }
              Text {
                textFormat: Text.PlainText
                text: parent.modelData.name + " " + Commons.I18n.formatNumber(parent.modelData.count)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // ---- search ---------------------------------------------------------
      TextField {
        id: search
        Layout.fillWidth: true
        leftPadding: Style.space(32)
        placeholderText: strings.t("search.placeholder")
        background: Rectangle {
          radius: root.radius
          color: root.subtle
          border.width: search.activeFocus ? 1 : 0
          border.color: Qt.alpha(root.accent, 0.6)
        }
        onTextEdited: root.query = text
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.handleKey(event, search)) event.accepted = true
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(11)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "\u{f0349}"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // ---- sender tabs ----------------------------------------------------
      // Scrolls sideways with the wheel or the edge arrows; Tab / Shift+Tab
      // in the search field cycles through them.
      Item {
        id: tabStrip
        Layout.fillWidth: true
        Layout.preferredHeight: tabsRow.implicitHeight
        visible: root.topApps.length > 1

        readonly property bool canLeft: tabs.contentX > 1
        readonly property bool canRight: tabs.contentX < tabs.contentWidth - tabs.width - 1

        function scrollTo(x) {
          var max = Math.max(0, tabs.contentWidth - tabs.width)
          tabScroll.to = Math.max(0, Math.min(max, x))
          tabScroll.restart()
        }
        function step(dir) { scrollTo(tabs.contentX + dir * tabs.width * 0.6) }
        // Bring the selected tab into view, with a little room either side.
        function reveal() {
          for (var i = 0; i < tabsRow.children.length; i++) {
            var t = tabsRow.children[i]
            if (!t.selected) continue
            var pad = Style.space(36)
            if (t.x - pad < tabs.contentX) scrollTo(t.x - pad)
            else if (t.x + t.width + pad > tabs.contentX + tabs.width) scrollTo(t.x + t.width + pad - tabs.width)
            return
          }
        }

        Flickable {
          id: tabs
          anchors.fill: parent
          contentWidth: tabsRow.implicitWidth
          contentHeight: height
          flickableDirection: Flickable.HorizontalFlick
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          NumberAnimation on contentX {
            id: tabScroll
            running: false
            duration: Style.duration(200)
            easing.type: Easing.OutCubic
          }

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              var d = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y
              tabScroll.stop()
              var max = Math.max(0, tabs.contentWidth - tabs.width)
              tabs.contentX = Math.max(0, Math.min(max, tabs.contentX - d * 0.6))
            }
          }

          Row {
            id: tabsRow
            spacing: Style.space(18)

            Tab {
              label: strings.t("filter.all")
              count: root.allRows.length
              selected: root.appFilter === ""
              onClicked: root.appFilter = ""
            }
            Repeater {
              model: root.topApps
              Tab {
                required property var modelData
                label: modelData.app
                count: modelData.count
                selected: root.appFilter === modelData.app
                onClicked: root.appFilter = root.appFilter === modelData.app ? "" : modelData.app
              }
            }
          }
        }

        TabArrow { anchors.left: parent.left; glyph: "\u{f0141}"; shown: tabStrip.canLeft; fadeToRight: true; onClicked: tabStrip.step(-1) }
        TabArrow { anchors.right: parent.right; glyph: "\u{f0142}"; shown: tabStrip.canRight; fadeToRight: false; onClicked: tabStrip.step(1) }
      }

      // ---- list -----------------------------------------------------------
      ListView {
        id: list
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.topMargin: -Style.space(6)
        clip: true
        spacing: Style.space(2)
        model: rowsModel
        visible: count > 0
        boundsBehavior: Flickable.StopAtBounds
        section.property: "day"
        section.delegate: Item {
          required property string section
          width: list.width
          height: sectionText.implicitHeight + Style.space(18)
          Text {
            id: sectionText
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            textFormat: Text.PlainText
            text: parent.section.toUpperCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }
        }

        delegate: Rectangle {
          id: item
          required property int index
          required property string key
          required property string appIcon
          required property string glyph
          required property string source
          required property string app
          required property int urgency
          required property int pid
          required property real ts
          required property bool unread
          required property string name
          required property string via
          required property string brandGlyph
          required property string brandMono
          required property string brandColor
          required property string title
          required property string sender
          required property string text
          required property string letter
          required property string letterColor
          required property string primaryText
          required property string secondaryText
          required property bool hasPrimary
          required property bool hasSecondary
          required property bool pinned
          required property string groupKey
          required property int groupSize
          required property bool isChild
          required property bool open

          readonly property bool useLetter: root.unknownIcon === "letter" && letter !== ""
          readonly property bool known: brandGlyph !== "" || brandMono !== ""
          // Our signature: a corner dot and an edge stripe in the sender's colour.
          readonly property bool hasMark: urgency === 2 || known || useLetter
          readonly property color mark: urgency === 2 ? root.urgentColor
            : (brandColor !== "" ? brandColor : (useLetter ? letterColor : root.fg))

          readonly property bool hovered: hover.hovered
          readonly property bool selected: root.selectedIndex === index
          // Logos keep their real colour on a white tile; monochrome brands
          // (X, GitHub) go near-black, everything else a deepened accent.
          readonly property color tone: urgency === 2 ? root.urgentColor
            : (brandColor !== "" ? brandColor : (known ? "#111111" : Qt.darker(root.accent, 1.35)))
          readonly property string iconUrl: !known && !useLetter ? root.iconSource(appIcon) : ""
          readonly property real tileSize: Style.space(36)
          readonly property real gutter: Style.space(10)

          width: list.width
          implicitHeight: body.implicitHeight + (isChild ? Style.space(12) : Style.space(20))
          radius: root.radius
          color: hovered || selected ? root.subtle : "transparent"
          border.width: selected ? 1 : 0
          border.color: Qt.alpha(root.accent, 0.45)
          Behavior on color { ColorAnimation { duration: Style.duration(120) } }

          HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
          MouseArea {
            anchors.fill: parent
            onClicked: root.focusApp({ pid: item.pid, source: item.source, app: item.app })
          }

          // Edge stripe; a group's folded-out rows keep a fainter one.
          Rectangle {
            visible: item.hasMark
            x: 0
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: item.isChild ? Style.space(4) : Style.space(12)
            anchors.bottomMargin: item.isChild ? Style.space(4) : Style.space(12)
            width: Style.space(3)
            radius: width / 2
            color: item.mark
            opacity: item.isChild ? 0.35 : (item.hovered ? 1 : 0.85)
          }

          // Folded-out rows hang off a thread from the group's tile.
          Rectangle {
            visible: item.isChild
            x: item.gutter + item.tileSize / 2 - width / 2
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: Qt.alpha(item.mark, 0.35)
          }

          // Time, unread dot and pin; swapped for actions on hover.
          Row {
            id: meta
            anchors.right: parent.right
            anchors.rightMargin: item.gutter
            anchors.top: parent.top
            anchors.topMargin: item.isChild ? Style.space(6) : Style.space(10)
            spacing: Style.space(6)
            z: 3

            Row {
              visible: item.hovered || item.selected
              spacing: Style.space(2)
              RowAction {
                glyph: item.pinned ? "\u{f0404}" : "\u{f0403}"
                active: item.pinned
                onClicked: root.togglePin(item.key)
              }
              RowAction { glyph: "\u{f018f}"; onClicked: root.copyRow({ title: item.title, sender: item.sender, text: item.text }) }
              RowAction { glyph: "\u{f0156}"; onClicked: root.removeEntry(item.key) }
            }
            Text {
              visible: !(item.hovered || item.selected) && item.pinned
              textFormat: Text.PlainText
              text: "\u{f0403}"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              visible: !(item.hovered || item.selected)
              textFormat: Text.PlainText
              text: root.timeLabel(item.ts, root.now)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Rectangle {
              visible: item.unread && !(item.hovered || item.selected)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(6); height: width; radius: width / 2
              color: root.accent
            }
          }

          RowLayout {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: item.isChild ? Style.space(6) : Style.space(10)
            anchors.leftMargin: item.gutter
            anchors.rightMargin: item.gutter
            spacing: Style.space(12)

            // Sender tile: brand logo in its colour, else app icon, else glyph.
            // Centred on the row, so taller rows don't leave a gap under it.
            // Folded-out rows keep the space but not the tile.
            Item {
              Layout.alignment: Qt.AlignVCenter
              Layout.preferredWidth: item.tileSize
              Layout.preferredHeight: item.isChild ? 1 : item.tileSize

              Rectangle {
                anchors.fill: parent
                visible: !item.isChild
                radius: root.radius
                color: "#FFFFFF"
                border.width: 1
                border.color: Qt.alpha("#000000", 0.08)

                // Corner dot, ringed in the panel colour so it sits cleanly on the tile's edge.
                Rectangle {
                  visible: item.hasMark
                  z: 2
                  width: Style.space(11); height: width
                  radius: width / 2
                  x: parent.width - width + Style.space(4)
                  y: -Style.space(4)
                  color: item.mark
                  border.width: Style.space(2)
                  border.color: Commons.Color.popups.background
                }

                Image {
                  id: appImage
                  anchors.centerIn: parent
                  width: Style.space(22); height: width
                  visible: item.iconUrl !== "" && status === Image.Ready
                  source: item.iconUrl
                  fillMode: Image.PreserveAspectFit
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  asynchronous: true
                  smooth: true
                }
                // Letter tiles: unknown sites, and known brands with no logo glyph.
                Text {
                  anchors.centerIn: parent
                  visible: item.useLetter || (item.brandGlyph === "" && item.brandMono !== "")
                  textFormat: Text.PlainText
                  text: item.brandMono !== "" ? item.brandMono : item.letter
                  color: item.brandMono !== "" ? item.tone : item.letterColor
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(Style.font.title * 1.3)
                  font.bold: true
                }
                Text {
                  anchors.centerIn: parent
                  visible: !appImage.visible && !item.useLetter && !(item.brandGlyph === "" && item.brandMono !== "")
                  textFormat: Text.PlainText
                  text: item.brandGlyph !== "" ? item.brandGlyph : (item.glyph !== "" ? item.glyph : "\u{f009a}")
                  color: item.tone
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(Style.font.title * 1.45)
                }
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              Layout.rightMargin: item.isChild ? meta.width + Style.space(8) : 0
              spacing: Style.space(3)

              // name · via Zen   (time / actions sit in `meta`, top right)
              RowLayout {
                Layout.fillWidth: true
                Layout.rightMargin: meta.width + Style.space(8)
                visible: !item.isChild
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: item.name
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  Layout.maximumWidth: Style.space(170)
                }
                Text {
                  visible: item.via !== ""
                  textFormat: Text.PlainText
                  text: strings.t("row.via").arg(item.via)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }
                Item { visible: item.via === ""; Layout.fillWidth: true }
              }

              // StyledText built by Model: links and search matches are the
              // only markup; everything the sender wrote is escaped.
              Text {
                Layout.fillWidth: true
                visible: item.hasPrimary
                textFormat: Text.StyledText
                text: item.primaryText
                color: Qt.alpha(root.fg, item.isChild ? 0.8 : 0.92)
                linkColor: root.accent
                font.family: root.fontFamily
                font.pixelSize: item.isChild ? Style.font.bodySmall : Style.font.body
                wrapMode: Text.Wrap
                maximumLineCount: item.hovered || item.selected ? 6 : 2
                elide: Text.ElideRight
                lineHeight: 1.1
                onLinkActivated: function(link) { root.openLink(link) }
              }

              Text {
                Layout.fillWidth: true
                visible: item.hasSecondary
                textFormat: Text.StyledText
                text: item.secondaryText
                color: root.dim
                linkColor: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                maximumLineCount: item.hovered || item.selected ? 6 : 2
                elide: Text.ElideRight
                lineHeight: 1.1
                onLinkActivated: function(link) { root.openLink(link) }
              }

              // "+5 more" / "Show less" on a group's first row.
              Rectangle {
                visible: !item.isChild && item.groupSize > 1
                Layout.topMargin: Style.space(4)
                implicitWidth: moreText.implicitWidth + Style.space(14)
                implicitHeight: moreText.implicitHeight + Style.space(6)
                radius: root.radius
                color: moreHover.hovered ? Qt.alpha(item.mark, 0.22) : Qt.alpha(item.mark, 0.12)
                z: 3

                Text {
                  id: moreText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: item.open ? strings.t("group.less")
                    : strings.tn("group.more", item.groupSize - 1).arg(Commons.I18n.formatNumber(item.groupSize - 1))
                  color: item.brandColor !== "" ? item.mark : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
                MouseArea { anchors.fill: parent; onClicked: root.toggleGroup(item.groupKey) }
              }
            }
          }
        }
      }

      // ---- empty state ----------------------------------------------------
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        visible: list.count === 0

        Column {
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: "\u{f009a}"
            color: Qt.alpha(root.fg, 0.18)
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge * 1.3
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: root.query.trim() !== "" || root.appFilter !== "" ? strings.t("empty.nomatch") : strings.t("empty.none")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }
  }

  // ================================================================ PARTS

  component IconButton: Rectangle {
    id: ib
    property string glyph: ""
    property string hint: ""
    property string label: ""
    property color tint: root.dim
    property bool on: false
    signal clicked()

    implicitWidth: label !== "" ? ibRow.implicitWidth + Style.space(16) : Style.space(30)
    Behavior on implicitWidth { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
    implicitHeight: Style.space(30)
    radius: root.radius
    opacity: enabled ? 1 : 0.35
    color: on ? Qt.alpha(tint, 0.16) : (ibHover.hovered && enabled ? root.subtle : "transparent")

    HoverHandler { id: ibHover; cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor }
    TapHandler { onTapped: if (ib.enabled) ib.clicked() }

    Row {
      id: ibRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: ib.glyph
        color: ibHover.hovered && !ib.on ? root.fg : ib.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
      Text {
        visible: ib.label !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: ib.label
        color: ib.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    // Small label under the button while hovered.
    Rectangle {
      visible: ibHover.hovered && ib.hint !== ""
      anchors.top: parent.bottom
      anchors.topMargin: Style.space(4)
      anchors.right: parent.right
      z: 10
      width: hintText.implicitWidth + Style.space(12)
      height: hintText.implicitHeight + Style.space(6)
      radius: root.radius
      color: Commons.Color.background
      border.width: 1
      border.color: root.line
      Text {
        id: hintText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: ib.hint
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component Tab: Item {
    id: tab
    property string label: ""
    property int count: 0
    property bool selected: false
    signal clicked()

    implicitWidth: tabRow.implicitWidth
    implicitHeight: tabRow.implicitHeight + Style.space(8)

    HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: tab.clicked() }

    Row {
      id: tabRow
      spacing: Style.space(5)
      Text {
        textFormat: Text.PlainText
        text: tab.label
        color: tab.selected || tabHover.hovered ? root.fg : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: tab.selected
      }
      Text {
        textFormat: Text.PlainText
        text: Commons.I18n.formatNumber(tab.count)
        color: tab.selected ? root.accent : Qt.alpha(root.dim, 0.8)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        y: Math.round((Style.font.bodySmall - Style.font.caption) * 0.8)
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: 2
      radius: 1
      color: root.accent
      opacity: tab.selected ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(150) } }
    }
  }

  component TabArrow: Item {
    id: arrow
    property string glyph: ""
    property bool shown: false
    property bool fadeToRight: true
    signal clicked()

    width: Style.space(40)
    height: parent ? parent.height : 0
    opacity: shown ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }

    // Fades the tabs out under the arrow.
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: arrow.fadeToRight ? Commons.Color.popups.background : Qt.alpha(Commons.Color.popups.background, 0) }
        GradientStop { position: 0.55; color: Commons.Color.popups.background }
        GradientStop { position: 1.0; color: arrow.fadeToRight ? Qt.alpha(Commons.Color.popups.background, 0) : Commons.Color.popups.background }
      }
    }

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      anchors.verticalCenterOffset: -Style.space(4)
      x: arrow.fadeToRight ? 0 : parent.width - width
      width: Style.space(22); height: width
      radius: root.radius
      color: arrowHover.hovered ? root.subtle : "transparent"
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: arrow.glyph
        color: arrowHover.hovered ? root.fg : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
      HoverHandler { id: arrowHover; cursorShape: Qt.PointingHandCursor }
      TapHandler { onTapped: arrow.clicked() }
    }
  }

  component RowAction: Rectangle {
    id: ra
    property string glyph: ""
    property bool active: false
    signal clicked()

    width: Style.space(22)
    height: Style.space(18)
    radius: root.radius
    color: raHover.hovered ? Qt.alpha(root.fg, 0.1) : "transparent"

    HoverHandler { id: raHover; cursorShape: Qt.PointingHandCursor }
    // A MouseArea above the row's own takes the click, so the row doesn't also jump to the app.
    MouseArea { anchors.fill: parent; onClicked: ra.clicked() }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ra.glyph
      color: ra.active ? root.accent : (raHover.hovered ? root.fg : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
