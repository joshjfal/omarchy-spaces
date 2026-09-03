// Spaces - a macOS-style "all spaces" overlay for Hyprland / Omarchy.
//
// A "space" N is workspace N + i*OFFSET on the i-th monitor (primary = i 0);
// every monitor flips together. This overlay shows spaces 1..SPACES_COUNT
// (plus any occupied space beyond) as a card carrying a screenshot of each
// monitor, the apps running there, and a keybind bar.
//
//   arrows / tab   move            enter   switch to the selected space
//   1 - 0          jump + switch   type    filter by app name, enter to accept
//   esc            clear filter, then close
//
// Screenshots are PNG thumbnails written by scripts/space-snapshot (via grim),
// named with the apps that were on the workspace when captured. A pane shows
// the thumbnail only while that key still matches the live window list;
// otherwise (never visited, windows changed) it shows a schematic layout of
// the actual windows, or "empty". Thumbnails live in ~/.cache/joshj-spaces.
//
// Bound to SUPER+CTRL+DOWN. The shell summons this via
// `omarchy-shell shell toggle joshj.spaces` and hands the payload to open();
// hide() calls close().

import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons

Item {
  id: root

  // Injected by the shell's plugin loader.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selectedIndex: 0
  property var spaces: []
  property string filter: ""
  // Bumped to make the screenshot <Image>s reload from disk.
  property int snapRevision: 0

  readonly property int offset: {
    var e = parseInt(Quickshell.env("SPACES_OFFSET"))
    return (!isNaN(e) && e > 0) ? e : 10
  }
  // How many spaces the overlay always shows (matches scripts/space-cycle).
  readonly property int spacesCount: {
    var e = parseInt(Quickshell.env("SPACES_COUNT"))
    return (!isNaN(e) && e > 0) ? e : 5
  }

  readonly property string cacheDir:
    (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/joshj-spaces"

  // ---------------------------------------------------------------- theming
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color scrim: Color.menu.scrim

  function fg(a) {
    return Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, a)
  }

  readonly property int previewHeight: {
    var count = Math.max(1, root.displayMonitors().length)
    if (count >= 4) return Style.space(84)
    if (count === 3) return Style.space(104)
    return Style.space(140)
  }
  readonly property int cardPadding: Style.space(12)
  readonly property int cardGap: Style.space(16)
  readonly property int previewGap: Style.space(8)
  readonly property int columns: {
    var n = root.spaces.length
    if (n === 0) return 1
    var maxCols = root.displayMonitors().length >= 3 ? 3 : 5
    return Math.max(1, Math.min(maxCols, n))
  }

  // ------------------------------------------------------------ monitor data
  function monitorList() {
    var out = []
    var vals = (typeof Hyprland !== "undefined" && Hyprland.monitors && Hyprland.monitors.values)
      ? Hyprland.monitors.values : []
    for (var i = 0; i < vals.length; i++) {
      var m = vals[i]
      var ipc = m.lastIpcObject || ({})
      var t = ipc.transform !== undefined ? ipc.transform : (m.transform || 0)
      var scale = ipc.scale || m.scale || 1
      var w = ipc.width || m.width || 1920
      var h = ipc.height || m.height || 1080
      var rotated = (t === 1 || t === 3 || t === 5 || t === 7)
      var lw = Math.round((rotated ? h : w) / scale)
      var lh = Math.round((rotated ? w : h) / scale)
      var activeId = -1
      if (m.activeWorkspace && m.activeWorkspace.id !== undefined) activeId = m.activeWorkspace.id
      else if (ipc.activeWorkspace && ipc.activeWorkspace.id !== undefined) activeId = ipc.activeWorkspace.id
      out.push({
        name: m.name,
        listIndex: i,
        x: ipc.x !== undefined ? ipc.x : (m.x || 0),
        y: ipc.y !== undefined ? ipc.y : (m.y || 0),
        area: w * h,
        logicalW: lw,
        logicalH: lh,
        activeWorkspaceId: activeId
      })
    }
    return out
  }

  // Monitors in workspace-assignment order: primary first (SPACES_PRIMARY if
  // set and connected, else the largest by pixel area), then the rest ordered
  // by physical position. Each monitor's index here is its offset multiplier.
  // Mirrors scripts/space-common.sh.
  function assignedMonitors() {
    var mons = root.monitorList()
    if (mons.length === 0) return []

    var byPos = mons.slice().sort(function(a, b) {
      return (a.x - b.x) || (a.y - b.y) || (a.listIndex - b.listIndex)
    })

    var want = Quickshell.env("SPACES_PRIMARY")
    var primary = null
    if (want) {
      for (var i = 0; i < byPos.length; i++)
        if (byPos[i].name === want) { primary = byPos[i]; break }
    }
    if (!primary) {
      primary = byPos[0]
      for (var j = 1; j < byPos.length; j++)
        if (byPos[j].area > primary.area) primary = byPos[j]
    }

    var ordered = [primary]
    for (var k = 0; k < byPos.length; k++)
      if (byPos[k].name !== primary.name) ordered.push(byPos[k])

    for (var idx = 0; idx < ordered.length; idx++)
      ordered[idx].offsetIndex = idx
    return ordered
  }

  function displayMonitors() {
    return root.assignedMonitors().slice().sort(function(a, b) {
      return (a.x - b.x) || (a.y - b.y) || (a.listIndex - b.listIndex)
    })
  }

  function primaryMonitor() {
    var a = root.assignedMonitors()
    return a.length ? a[0] : null
  }

  function foldId(id) {
    if (id > root.offset) return ((id - 1) % root.offset) + 1
    return id
  }

  function sanitize(name) {
    return String(name).replace(/[^A-Za-z0-9._-]/g, "_")
  }

  // A screenshot is trusted only when its filename carries a key that still
  // matches the apps currently on that workspace (space-snapshot writes it, and
  // only while the space is actually on screen). Otherwise the pane falls back
  // to the schematic window layout.
  function appsKeyForWs(wsId) {
    var tops = root.workspaceToplevels(wsId)
    var set = ({})
    for (var i = 0; i < tops.length; i++) {
      var ipc = tops[i].lastIpcObject || ({})
      var c = String(ipc["class"] || (tops[i].wayland ? tops[i].wayland.appId : "") || "").toLowerCase()
      if (c) set[c] = true
    }
    var arr = []
    for (var k in set) arr.push(k)
    arr.sort()
    return arr.join("_").replace(/[^A-Za-z0-9_]/g, ".").slice(0, 64)
  }

  function snapshotUrl(spaceN, monName, key) {
    if (!key) return ""
    return "file://" + root.cacheDir + "/space-" + spaceN + "-"
      + root.sanitize(monName) + "--" + key + ".png"
  }

  // ---------------------------------------------------------- workspace data
  function workspaceToplevels(id) {
    var vals = (Hyprland.workspaces && Hyprland.workspaces.values) ? Hyprland.workspaces.values : []
    for (var i = 0; i < vals.length; i++)
      if (vals[i].id === id)
        return (vals[i].toplevels && vals[i].toplevels.values) ? vals[i].toplevels.values : []
    return []
  }

  function currentSpaceNumber() {
    var p = root.primaryMonitor()
    var id = (p && p.activeWorkspaceId > 0)
      ? p.activeWorkspaceId
      : (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1)
    id = root.foldId(id)
    return (id >= 1 && id <= root.offset) ? id : 1
  }

  function prettyApp(cls) {
    var s = String(cls || "").trim()
    if (!s) return "App"
    if (s.indexOf(".") >= 0) {
      var parts = s.split(".")
      s = parts[parts.length - 1] || s
    }
    return s.charAt(0).toUpperCase() + s.slice(1)
  }

  function windowsFor(wsId) {
    var tops = root.workspaceToplevels(wsId)
    var out = []
    for (var i = 0; i < tops.length && out.length < 24; i++) {
      var wnd = tops[i]
      var ipc = wnd.lastIpcObject || ({})
      var at = ipc.at || [0, 0]
      var size = ipc.size || [400, 300]
      out.push({
        appClass: root.prettyApp(ipc["class"] || (wnd.wayland ? wnd.wayland.appId : "") || "App"),
        title: String(wnd.title || ipc.title || ""),
        x: at[0], y: at[1], w: size[0], h: size[1]
      })
    }
    return out
  }

  // Workspace ids that make up space N, one per monitor.
  function workspaceIdsForSpace(n) {
    var mons = root.displayMonitors()
    var ids = []
    for (var i = 0; i < mons.length; i++)
      ids.push(n + (mons[i].offsetIndex || 0) * root.offset)
    if (ids.length === 0) ids.push(n)
    return ids
  }

  // Unique app names across every monitor of space N.
  function appsForSpace(n) {
    var ids = root.workspaceIdsForSpace(n)
    var seen = ({})
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var wins = root.windowsFor(ids[i])
      for (var j = 0; j < wins.length; j++) {
        var key = wins[j].appClass.toLowerCase()
        if (!seen[key]) { seen[key] = true; out.push(wins[j].appClass) }
      }
    }
    return out
  }

  function spaceMatches(n, f) {
    if (!f) return true
    f = f.toLowerCase()
    var ids = root.workspaceIdsForSpace(n)
    for (var i = 0; i < ids.length; i++) {
      var wins = root.windowsFor(ids[i])
      for (var j = 0; j < wins.length; j++) {
        if (wins[j].appClass.toLowerCase().indexOf(f) >= 0) return true
        if (wins[j].title.toLowerCase().indexOf(f) >= 0) return true
      }
    }
    return false
  }

  function matchingIndices() {
    if (!root.filter) return null
    var out = []
    for (var i = 0; i < root.spaces.length; i++)
      if (root.spaceMatches(root.spaces[i].n, root.filter)) out.push(i)
    return out
  }

  onFilterChanged: {
    var m = root.matchingIndices()
    if (m && m.length && m.indexOf(root.selectedIndex) < 0)
      root.selectedIndex = m[0]
  }

  // --------------------------------------------------------- build the model
  //
  // Always spaces 1..SPACES_COUNT, plus any occupied space beyond that so
  // nothing is ever hidden.
  function computeSpaces() {
    var set = ({})
    for (var s = 1; s <= root.spacesCount && s <= root.offset; s++) set[s] = true

    var vals = (Hyprland.workspaces && Hyprland.workspaces.values) ? Hyprland.workspaces.values : []
    for (var i = 0; i < vals.length; i++) {
      var w = vals[i]
      if (w.id < 1) continue
      if (!w.toplevels || w.toplevels.values.length === 0) continue
      var n = root.foldId(w.id)
      if (n >= 1 && n <= root.offset) set[n] = true
    }
    set[root.currentSpaceNumber()] = true

    var list = []
    for (var k in set) list.push(parseInt(k))
    list.sort(function(a, b) { return a - b })
    if (list.length > root.offset) list = list.slice(0, root.offset)

    var out = []
    for (var j = 0; j < list.length; j++)
      out.push({ n: list[j] })
    return out
  }

  function reconcileModel(list) {
    for (var i = 0; i < list.length; i++) {
      var existing = -1
      for (var j = i; j < spaceModel.count; j++) {
        if (spaceModel.get(j).n === list[i].n) { existing = j; break }
      }
      if (existing < 0) spaceModel.insert(i, { n: list[i].n })
      else if (existing !== i) spaceModel.move(existing, i, 1)
    }
    while (spaceModel.count > list.length) spaceModel.remove(spaceModel.count - 1)
  }

  function rebuild() {
    var list = root.computeSpaces()
    root.reconcileModel(list)
    root.spaces = list
    if (root.selectedIndex >= list.length) root.selectedIndex = list.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function indexOfSpace(n) {
    for (var i = 0; i < root.spaces.length; i++)
      if (root.spaces[i].n === n) return i
    return 0
  }

  // ------------------------------------------------------------- navigation
  function move(dx, dy) {
    var n = root.spaces.length
    if (n === 0) return

    var vis = root.matchingIndices()
    if (vis && vis.length) {
      var pos = vis.indexOf(root.selectedIndex)
      var step = (dx + dy) >= 0 ? 1 : -1
      if (pos < 0) { root.selectedIndex = vis[0]; return }
      root.selectedIndex = vis[(pos + step + vis.length) % vis.length]
      return
    }

    var idx = root.selectedIndex
    if (dx !== 0) idx = (idx + dx + n) % n
    if (dy !== 0) {
      var next = idx + dy * root.columns
      if (next >= 0 && next < n) idx = next
    }
    root.selectedIndex = Math.max(0, Math.min(n - 1, idx))
  }

  function scriptPath(name) {
    var dir = (root.manifest && root.manifest.__sourceDir)
      ? String(root.manifest.__sourceDir)
      : (Quickshell.env("HOME") + "/.config/omarchy/plugins/joshj.spaces")
    return dir.replace(/\/+$/, "") + "/scripts/" + name
  }

  function switchTo(n) {
    Quickshell.execDetached([root.scriptPath("space-switch"), String(n)])
    root.dismiss()
  }

  function activate() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.spaces.length) { root.dismiss(); return }
    root.switchTo(root.spaces[root.selectedIndex].n)
  }

  // Snapshots are taken only by space-switch (settled desktop, no overlay). The
  // overlay just marks itself on screen so a switch made while it is open does
  // not bake it into a thumbnail.
  function markOnScreen(on) {
    Quickshell.execDetached(on
      ? ["sh", "-c", "mkdir -p " + root.cacheDir + " && touch " + root.cacheDir + "/.overlay-open"]
      : ["rm", "-f", root.cacheDir + "/.overlay-open"])
  }
  onOpenedChanged: root.markOnScreen(root.opened)

  // ----------------------------------------------------- shell entry points
  function open(payloadJson) {
    root.filter = ""
    root.rebuild()
    root.selectedIndex = root.indexOfSpace(root.currentSpaceNumber())
    root.opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    // Pick up a thumbnail that may have just been written by space-switch.
    snapReloadTimer.ticks = 0
    snapReloadTimer.restart()
  }

  function close() {
    root.opened = false
    root.filter = ""
  }

  function dismiss() {
    root.opened = false
    root.filter = ""
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "joshj.spaces")
  }

  Component.onCompleted: {
    root.rebuild()
    root.snapRevision = 1
    root.markOnScreen(false)   // clear a stale flag from a crashed session
  }

  Timer {
    id: snapReloadTimer
    property int ticks: 0
    interval: 450
    repeat: true
    onTriggered: {
      root.snapRevision++
      if (++ticks >= 4) { stop(); ticks = 0 }
    }
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      if (root.opened) root.rebuild()
      root.snapRevision++
    }
  }

  ListModel { id: spaceModel }

  // Keybind bar entries. The clear-filter hint is appended only while filtering.
  readonly property var hintModel: {
    var base = [
      { k: "↑ ↓ ← →", l: "Navigate" },
      { k: "⏎", l: "Switch" },
      { k: "1 - 0", l: "Jump" },
      { k: "type", l: "Filter by app" },
      { k: "esc", l: root.filter.length > 0 ? "Clear filter" : "Close" }
    ]
    if (root.filter.length > 0)
      base.splice(4, 0, { k: "⌫", l: "Backspace" })
    return base
  }

  PanelWindow {
    id: panel
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "joshj-spaces"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {
      width: root.opened ? panel.width : 0
      height: root.opened ? panel.height : 0
    }

    Rectangle {
      anchors.fill: parent
      visible: root.opened
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      visible: root.opened
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.filter.length > 0) root.filter = ""
          else root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate(); event.accepted = true
        } else if (event.key === Qt.Key_Backspace) {
          root.filter = root.filter.slice(0, -1); event.accepted = true
        } else if (event.key === Qt.Key_Left) {
          root.move(-1, 0); event.accepted = true
        } else if (event.key === Qt.Key_Right) {
          root.move(1, 0); event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move(0, -1); event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move(0, 1); event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.move((event.modifiers & Qt.ShiftModifier) ? -1 : 1, 0); event.accepted = true
        } else if (root.filter.length === 0
                   && event.key >= Qt.Key_1 && event.key <= Qt.Key_9
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          root.switchTo(event.key - Qt.Key_0); event.accepted = true
        } else if (root.filter.length === 0 && event.key === Qt.Key_0
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          root.switchTo(10); event.accepted = true
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 0x20
                   && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
          if (event.text.trim().length > 0) root.filter += event.text.toLowerCase()
          event.accepted = true
        }
      }
    }

    Rectangle {
      id: dialog
      visible: root.opened
      anchors.centerIn: parent
      width: Math.min(panel.width - Style.space(48), layout.implicitWidth + Style.space(48))
      height: layout.implicitHeight + Style.space(44)
      radius: Style.cornerRadius
      color: root.background
      border.width: Math.max(1, Style.space(1))
      border.color: root.borderColor

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        id: layout
        anchors.centerIn: parent
        spacing: Style.space(14)

        // ---- header ------------------------------------------------------
        Item {
          width: parent.width
          height: headerRow.height

          Row {
            id: headerRow
            spacing: Style.space(10)
            Text {
              text: "Spaces"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: headerRow.verticalCenter
            spacing: Style.space(6)
            visible: root.filter.length > 0
            Text {
              text: "filter"
              color: root.fg(0.5)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Rectangle {
              radius: Style.space(4)
              color: root.fg(0.10)
              border.width: 1
              border.color: root.fg(0.25)
              height: filterText.implicitHeight + Style.space(6)
              width: filterText.implicitWidth + Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                id: filterText
                anchors.centerIn: parent
                text: root.filter + "▏"
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- the grid of spaces ----------------------------------------
        Grid {
          id: grid
          anchors.horizontalCenter: parent.horizontalCenter
          columns: root.columns
          rowSpacing: root.cardGap
          columnSpacing: root.cardGap

          Repeater {
            id: spaceRepeater
            model: spaceModel

            delegate: Item {
              id: card
              required property int index
              required property int n

              readonly property bool selected: index === root.selectedIndex
              readonly property bool isCurrent: card.n === root.currentSpaceNumber()
              readonly property bool matched: root.filter.length === 0 || root.spaceMatches(card.n, root.filter)
              readonly property var apps: root.appsForSpace(card.n)
              readonly property var panes: {
                var mons = root.displayMonitors()
                var arr = []
                for (var i = 0; i < mons.length; i++) {
                  arr.push({
                    wsId: card.n + (mons[i].offsetIndex || 0) * root.offset,
                    mon: mons[i]
                  })
                }
                if (arr.length === 0) arr.push({ wsId: card.n, mon: null })
                return arr
              }

              width: cardContent.implicitWidth + root.cardPadding * 2
              height: cardContent.implicitHeight + root.cardPadding * 2
              opacity: card.matched ? 1 : 0.32
              Behavior on opacity { NumberAnimation { duration: 110 } }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: card.selected
                  ? root.selectedBackground
                  : root.fg(cardMouse.containsMouse ? 0.10 : 0.05)
                border.width: card.selected ? Style.space(3)
                  : (card.isCurrent ? Style.space(2) : Math.max(1, Style.space(1)))
                border.color: card.selected ? root.selectedText
                  : (card.isCurrent
                      ? Qt.rgba(root.selectedText.r, root.selectedText.g, root.selectedText.b, 0.55)
                      : root.borderColor)
                scale: cardMouse.containsMouse && !card.selected ? 1.012 : 1
                Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
              }

              Column {
                id: cardContent
                x: root.cardPadding
                y: root.cardPadding
                spacing: Style.space(8)

                Row {
                  id: paneRow
                  spacing: root.previewGap

                  Repeater {
                    id: paneRepeater
                    model: card.panes

                    delegate: Item {
                      id: pane
                      required property var modelData
                      readonly property var mon: modelData.mon
                      readonly property real aspect: mon
                        ? mon.logicalW / Math.max(1, mon.logicalH)
                        : 16 / 9
                      readonly property var winList: root.windowsFor(pane.modelData.wsId)
                      readonly property string shotKey: root.appsKeyForWs(pane.modelData.wsId)
                      readonly property string shotBase: mon
                        ? root.snapshotUrl(card.n, mon.name, pane.shotKey) : ""

                      width: Math.max(Style.space(38), Math.round(root.previewHeight * aspect))
                      height: root.previewHeight

                      function reloadShot() {
                        shot.source = ""
                        if (pane.shotBase) shot.source = pane.shotBase
                      }
                      onShotBaseChanged: pane.reloadShot()
                      Component.onCompleted: pane.reloadShot()
                      Connections {
                        target: root
                        function onSnapRevisionChanged() { pane.reloadShot() }
                      }

                      Rectangle {
                        id: frame
                        anchors.fill: parent
                        radius: Math.max(2, Style.cornerRadius - Style.space(2))
                        clip: true
                        color: root.fg(0.06)
                        border.width: 1
                        border.color: root.fg(0.18)

                        // schematic window layout until a screenshot exists
                        Item {
                          anchors.fill: parent
                          anchors.margins: 2
                          visible: shot.status !== Image.Ready

                          Repeater {
                            model: pane.winList

                            Rectangle {
                              required property var modelData
                              readonly property real availW: frame.width - 4
                              readonly property real availH: frame.height - 4
                              readonly property real mx: pane.mon ? pane.mon.x : 0
                              readonly property real my: pane.mon ? pane.mon.y : 0
                              readonly property real mw: pane.mon ? Math.max(1, pane.mon.logicalW) : 1920
                              readonly property real mh: pane.mon ? Math.max(1, pane.mon.logicalH) : 1080
                              x: Math.max(0, Math.min(availW - width, (modelData.x - mx) / mw * availW))
                              y: Math.max(0, Math.min(availH - height, (modelData.y - my) / mh * availH))
                              width: Math.max(Style.space(18), Math.min(availW, modelData.w / mw * availW))
                              height: Math.max(Style.space(12), Math.min(availH, modelData.h / mh * availH))
                              radius: 2
                              color: root.fg(card.selected ? 0.20 : 0.12)
                              border.width: 1
                              border.color: root.fg(0.30)

                              Text {
                                anchors.fill: parent
                                anchors.margins: Style.space(4)
                                text: modelData.appClass
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                                color: root.fg(0.8)
                                font.family: Style.font.menuFamily
                                font.pixelSize: Style.font.caption
                              }
                            }
                          }
                        }

                        Text {
                          anchors.centerIn: parent
                          visible: shot.status !== Image.Ready && pane.winList.length === 0
                          text: "empty"
                          color: root.fg(0.4)
                          font.family: Style.font.menuFamily
                          font.pixelSize: Style.font.caption
                        }

                        Image {
                          id: shot
                          anchors.fill: parent
                          anchors.margins: 1
                          fillMode: Image.PreserveAspectCrop
                          cache: false
                          asynchronous: true
                          smooth: true
                          visible: status === Image.Ready
                        }
                      }
                    }
                  }
                }

                // ---- app names ---------------------------------------
                Flow {
                  width: paneRow.implicitWidth
                  spacing: Style.space(4)
                  visible: card.apps.length > 0

                  Repeater {
                    model: card.apps.slice(0, 6)

                    Rectangle {
                      required property var modelData
                      readonly property bool hit: root.filter.length > 0
                        && String(modelData).toLowerCase().indexOf(root.filter) >= 0
                      radius: Style.space(4)
                      color: hit ? Qt.rgba(root.selectedText.r, root.selectedText.g, root.selectedText.b, 0.20)
                                 : root.fg(0.09)
                      border.width: 1
                      border.color: hit ? root.selectedText : root.fg(0.16)
                      height: pill.implicitHeight + Style.space(4)
                      width: pill.implicitWidth + Style.space(12)

                      Text {
                        id: pill
                        anchors.centerIn: parent
                        text: modelData
                        textFormat: Text.PlainText
                        color: hit ? root.foreground : root.fg(0.7)
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Text {
                    visible: card.apps.length > 6
                    text: "+" + (card.apps.length - 6)
                    color: root.fg(0.5)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                    height: Style.space(18)
                    verticalAlignment: Text.AlignVCenter
                  }
                }

                // ---- label -----------------------------------------
                Text {
                  text: (card.isCurrent ? "●  " : "") + "Space " + (card.n === 10 ? "0" : card.n)
                  textFormat: Text.PlainText
                  color: card.selected ? root.foreground : root.fg(0.62)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                  font.bold: card.selected
                }
              }

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = card.index
                onClicked: root.switchTo(card.n)
              }
            }
          }
        }

        // ---- keybind bar -------------------------------------------------
        Rectangle {
          width: parent.width
          height: hintRow.height + Style.space(14)
          radius: Style.space(6)
          color: root.fg(0.05)
          border.width: 1
          border.color: root.fg(0.12)

          Row {
            id: hintRow
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)

            Repeater {
              model: root.hintModel

              Row {
                required property var modelData
                spacing: Style.space(6)

                Rectangle {
                  radius: Style.space(4)
                  color: root.fg(0.10)
                  border.width: 1
                  border.color: root.fg(0.22)
                  height: keycap.implicitHeight + Style.space(5)
                  width: Math.max(Style.space(20), keycap.implicitWidth + Style.space(10))
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    id: keycap
                    anchors.centerIn: parent
                    text: modelData.k
                    color: root.fg(0.85)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  text: modelData.l
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.fg(0.6)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
