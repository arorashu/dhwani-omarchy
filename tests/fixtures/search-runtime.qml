import QtQuick
import QtQuick.Window
import "PLUGIN_URL" as Dhwani

// Drives the real Service.qml against a fixture search API: stale-response
// supersession, raw-offset pagination, scope, shows mode, and artwork binding.
Window {
  id: root
  visible: true
  width: 320
  height: 100
  property bool artworkReady: false

  Dhwani.Service { id: service; apiBase: "API_BASE" }

  Image {
    width: 48
    height: 48
    source: service.searchEpisodes.length ? service.artworkFor(service.searchEpisodes[0]) : ""
    onStatusChanged: if (status === Image.Ready) root.artworkReady = true
  }

  Connections {
    target: service
    function onStateReadyChanged() {
      if (service.stateReady) Qt.callLater(function() { service.beginSearch("episodes", "stale", "") })
    }
  }

  function report(label) {
    console.log("SEARCH_" + label + ":" + JSON.stringify({
      query: service.searchQuery,
      kind: service.searchKind,
      episodes: service.searchEpisodes.length,
      shows: service.searchShows.length,
      total: service.searchTotal,
      next: service.searchNextOffset,
      loading: service.searchLoading,
      error: service.searchError,
      stale: service.searchEpisodes.filter(function(item) { return item.title.indexOf("STALE") === 0 }).length,
    }))
  }

  Timer {
    interval: 400
    running: true
    onTriggered: service.beginSearch("episodes", "alpha", "")
  }
  Timer {
    interval: 2600
    running: true
    onTriggered: { root.report("ALPHA"); service.pageSearch() }
  }
  Timer {
    interval: 3400
    running: true
    onTriggered: { root.report("PAGED"); service.beginSearch("episodes", "alpha", "9QqWbjH5mqlrsiaHMba1") }
  }
  Timer {
    interval: 4300
    running: true
    onTriggered: { root.report("SCOPED"); service.beginSearch("shows", "alpha", "9QqWbjH5mqlrsiaHMba1") }
  }
  Timer {
    interval: 5200
    running: true
    onTriggered: { root.report("SHOWS"); console.log("SEARCH_IMAGE:" + root.artworkReady); Qt.quit() }
  }
  Timer {
    interval: 15000
    running: true
    onTriggered: { console.error("search fixture timeout"); Qt.quit() }
  }
}
