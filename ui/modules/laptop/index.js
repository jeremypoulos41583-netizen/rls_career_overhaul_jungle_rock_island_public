import { createApp } from "vue"
import LaptopMain from "./views/LaptopMain.vue"

let appInstance = null

function showLaptop(show) {
  if (show && !appInstance) {
    console.log("[LaptopUI] showing laptop")
    const mount = document.createElement("div")
    mount.id = "laptop-ui"
    document.body.appendChild(mount)
    appInstance = createApp(LaptopMain)
    appInstance.mount("#laptop-ui")
  } else if (!show && appInstance) {
    console.log("[LaptopUI] hiding laptop")
    appInstance.unmount()
    document.getElementById("laptop-ui")?.remove()
    appInstance = null
  }
}

// listen for our hook
window.addEventListener("Laptop_Toggle", e => showLaptop(e.detail.visible))
console.log("[LaptopUI] bridge loaded and waiting for Laptop_Toggle")
