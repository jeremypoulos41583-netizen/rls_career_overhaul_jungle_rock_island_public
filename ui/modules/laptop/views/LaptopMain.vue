<template>
  <div class="laptop-shell">
    <div class="laptop-screen">
      <h1 class="title">Aloha MDT</h1>
      <p class="subtitle">Mission Terminal</p>

      <div class="app-buttons">
        <router-link class="btn" to="/laptop/bus">Bus Service</router-link>
        <router-link class="btn" to="/laptop/ambulance">Ambulance</router-link>
      </div>

      <router-view class="app-view" />
    </div>
  </div>
</template>

<script setup>
// nothing needed yet
</script>

<style scoped>
.laptop-shell {
  position: absolute;
  top: 0; left: 0;
  width: 100%; height: 100%;
  background: radial-gradient(circle at center, #1a1a1a 40%, #000 100%);
  display: flex; align-items: center; justify-content: center;
  font-family: "Overpass", sans-serif;
}
.laptop-screen {
  width: 90%; height: 80%;
  background: #d8e0f6;
  border: 3px solid #888;
  border-radius: 1rem;
  box-shadow: 0 0 30px rgba(0,0,0,0.7);
  padding: 2rem;
  text-align: center;
}
.title {
  font-size: 2rem;
  margin-bottom: 0.5rem;
}
.subtitle {
  font-size: 1rem;
  margin-bottom: 2rem;
  color: #333;
}
.app-buttons {
  display: flex;
  justify-content: center;
  gap: 1rem;
  margin-bottom: 2rem;
}
.btn {
  background: #2f2bff;
  color: #fff;
  padding: 0.75rem 1.5rem;
  border-radius: 8px;
  text-decoration: none;
  font-weight: bold;
}
.app-view {
  margin-top: 1rem;
}
</style>
