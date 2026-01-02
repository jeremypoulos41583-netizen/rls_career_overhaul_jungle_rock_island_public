import LaptopMain from "./views/LaptopMain.vue"
import AppBus from "./views/apps/AppBus.vue"
import AppAmbulance from "./views/apps/AppAmbulance.vue"

export default [
  {
    path: "/laptop",
    name: "laptop-main",
    component: LaptopMain,
    children: [
      { path: "bus", name: "laptop-bus", component: AppBus },
      { path: "ambulance", name: "laptop-ambulance", component: AppAmbulance }
    ]
  }
]
