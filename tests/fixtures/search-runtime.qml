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
      if (!service.stateReady) return
      Qt.callLater(function() {
        service.beginSearch("episodes", "stale", "")
        alphaSearch.start()
        alphaReport.start()
        pagedReport.start()
        scopedReport.start()
        showsReport.start()
      })
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
    id: alphaSearch
    interval: 400
    onTriggered: service.beginSearch("episodes", "alpha", "")
  }
  Timer {
    id: alphaReport
    interval: 2600
    onTriggered: { root.report("ALPHA"); service.pageSearch() }
  }
  Timer {
    id: pagedReport
    interval: 3400
    onTriggered: { root.report("PAGED"); service.beginSearch("episodes", "alpha", "9QqWbjH5mqlrsiaHMba1") }
  }
  Timer {
    id: scopedReport
    interval: 4300
    onTriggered: { root.report("SCOPED"); service.beginSearch("shows", "alpha", "9QqWbjH5mqlrsiaHMba1") }
  }
  Timer {
    id: showsReport
    interval: 5200
    onTriggered: { root.report("SHOWS"); console.log("SEARCH_IMAGE:" + root.artworkReady); Qt.quit() }
  }
  Timer {
    interval: 15000
    running: true
    onTriggered: { console.error("search fixture timeout"); Qt.quit() }
  }
}
