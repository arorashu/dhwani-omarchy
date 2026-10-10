import QtQuick
import QtQuick.Window
import "PLUGIN_URL" as Dhwani

// Exercise two real FileView atomic replacements after secure hydration.
Window {
  visible: true
  width: 240
  height: 80

  Dhwani.Service { id: service; apiBase: "API_BASE" }

  Connections {
    target: service
    function onStateReadyChanged() {
      if (!service.stateReady) return
      console.log("STORAGE_LOADED:" + service.queue.length + ":" + (service.queue.length ? service.queue[0].position : -1))
      var first = Object.assign({}, service.queue[0])
      first.position = 23
      service.queue = [first]
      service.saveState()
      secondWrite.start()
    }
  }

  Timer {
    id: secondWrite
    interval: 500
    onTriggered: {
      var second = Object.assign({}, service.queue[0])
      second.position = 47
      service.queue = [second]
      service.saveState()
      finish.start()
    }
  }

  Timer {
    id: finish
    interval: 800
    onTriggered: {
      console.log("STORAGE_WRITTEN:" + service.queue[0].position)
      Qt.quit()
    }
  }

  Timer {
    interval: 10000
    running: true
    onTriggered: { console.error("storage write fixture timeout"); Qt.quit() }
  }
}
