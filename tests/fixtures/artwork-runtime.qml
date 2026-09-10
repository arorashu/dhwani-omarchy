import QtQuick
import QtQuick.Window
import "PLUGIN_URL" as Dhwani

Window {
  id: root
  visible: true
  width: 300
  height: 100
  property int readyImages: 0
  property var rows: EPISODE_ROWS

  Dhwani.Service { id: service; apiBase: "API_BASE" }

  Row {
    Repeater {
      model: root.rows
      Image {
        required property var modelData
        property bool reported: false
        width: 80
        height: 80
        source: service.artworkFor(modelData)
        onStatusChanged: {
          if (status !== Image.Ready || reported) return
          reported = true
          root.readyImages++
          if (root.readyImages === 3) finish.start()
        }
      }
    }
  }

  // Wait for initial FileView hydration before requesting metadata.
  Connections {
    target: service
    function onStateReadyChanged() {
      if (service.stateReady) Qt.callLater(function() {
        service.ensureArtwork(root.rows)
        service.ensureArtwork(root.rows)
      })
    }
  }

  // Allow the service's debounced FileView write to complete before exiting.
  Timer {
    id: finish
    interval: 1000
    onTriggered: {
      console.log("ARTWORK_READY:" + root.readyImages)
      Qt.quit()
    }
  }
  Timer {
    interval: 15000
    running: true
    onTriggered: {
      console.error("Artwork timeout: " + root.readyImages + " images ready")
      Qt.quit()
    }
  }
}
