import QtQuick
import QtQuick.Window
import "PLUGIN_URL" as Dhwani

// Hydrates the real Service.qml from the state.json written by the harness:
// cached YouTube episode rows must be filtered while raw pagination offsets
// and the surviving rows' metadata are preserved across the restart.
Window {
  id: root
  visible: true
  width: 320
  height: 100

  Dhwani.Service { id: service; apiBase: "API_BASE" }

  Connections {
    target: service
    function onStateReadyChanged() {
      if (!service.stateReady) return
      Qt.callLater(function() {
        var record = service.showsById["9QqWbjH5mqlrsiaHMba1"] || {}
        var episodes = record.episodes || []
        console.log("HYDRATION:" + JSON.stringify({
          trending: service.trending.length,
          trendingPosition: service.trending.length ? service.trending[0].position : -1,
          trendingPublished: service.trending.length ? (service.trending[0].publication_date || "") : "",
          showEpisodes: episodes.length,
          showEpisodeId: episodes.length ? episodes[0].episodeId : "",
          showNextOffset: record.nextOffset,
          showTotal: record.total,
          showArtwork: record.artworkUrl || "",
          showFetchedAt: record.fetchedAt,
          showsNextOffset: service.showsNextOffset,
          showsTotal: service.showsTotal,
          showsItems: service.shows.length,
          queue: service.queue.length
        }))
        Qt.quit()
      })
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: { console.error("hydration fixture timeout"); Qt.quit() }
  }
}
