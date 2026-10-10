import QtQuick
import QtQuick.Window
import "PLUGIN_URL" as Dhwani

Window {
  visible: true
  width: 240
  height: 80

  Dhwani.Service { id: service; apiBase: "API_BASE" }

  Connections {
    target: service
    function onStorageFailedChanged() {
      if (!service.storageFailed) return
      console.log("STORAGE_FAILURE:" + service.storageReady + ":" + service.stateReady + ":" + service.errorText)
      Qt.callLater(Qt.quit)
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: { console.error("storage failure fixture timeout"); Qt.quit() }
  }
}
