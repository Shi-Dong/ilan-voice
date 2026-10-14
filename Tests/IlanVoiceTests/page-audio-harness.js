// Runs the iPhone page's script against fake browser objects and reports how it
// uses the phone's audio across a conversation. Prints one JSON line.
const fs = require("fs");
const script = fs.readFileSync(process.argv[2], "utf8");
const any = () => new Proxy(function () {}, {
  get: (t, k) => (k === Symbol.toPrimitive ? () => 0 : k === "then" ? undefined : any()),
  apply: () => any(), construct: () => any(), set: () => true,
});
const handlers = {};
const elements = {};
const el = id => elements[id] || (elements[id] = new Proxy({ id, style: { setProperty() {} }, classList: { add() {}, remove() {}, toggle() {} },
  textContent: "", addEventListener: (type, fn) => { (handlers[id + ":" + type] = handlers[id + ":" + type] || []).push(fn); },
  setPointerCapture() {}, getContext: () => any(), appendChild() {}, append() {}, click() {}, setAttribute() {} }, {
  get: (t, k) => (k in t ? t[k] : any()), set: (t, k, v) => { t[k] = v; return true; } }));
const timers = [];
const contexts = [];
class FakeAudioContext {
  constructor() { this.state = "running"; this.closed = false; this.currentTime = 0; this.sampleRate = 48000;
    this.destination = any(); this.audioWorklet = { addModule: async () => {} }; contexts.push(this); }
  resume() { if (!this.closed) this.state = "running"; return Promise.resolve(); }
  close() { this.closed = true; this.state = "closed"; return Promise.resolve(); }
  createOscillator() { return any(); } createGain() { return any(); } createDynamicsCompressor() { return any(); }
  createDelay() { return any(); } createBuffer() { return { getChannelData: () => new Float32Array(1), duration: 0 }; }
  createBufferSource() { return any(); } createMediaStreamSource() { return any(); } createAnalyser() { return any(); }
}
const sent = [];
const audioSessionTypes = [];
const g = {
  window: null, console,
  document: { getElementById: el, querySelector: () => el("q"), createElement: () => el("x" + Math.random()),
              body: el("body"), documentElement: el("html"), addEventListener() {}, hidden: false },
  navigator: { audioSession: { set type(v) { audioSessionTypes.push(v); }, get type() { return audioSessionTypes.at(-1); } },
               mediaDevices: { getUserMedia: async () => ({ getTracks: () => [{ stop() {} }] }) } },
  localStorage: { getItem: k => (k === "ilanToken" ? "t" : k === "ilanDevice" ? "d" : null), setItem() {}, removeItem() {} },
  location: { protocol: "https:", host: "h", search: "" }, URLSearchParams: class { get() { return null; } },
  WebSocket: class { constructor() { this.readyState = 1; setTimeout(() => this.onopen && this.onopen(), 0); }
                     send(m) { sent.push(m); } close() {} },
  AudioContext: FakeAudioContext, AudioWorkletNode: class { constructor() { this.port = {}; } connect() {} disconnect() {} },
  setTimeout: (fn, ms) => { timers.push({ fn, at: (ms || 0) }); return timers.length; }, clearTimeout() {},
  setInterval: () => 0, requestAnimationFrame() {}, ResizeObserver: class { observe() {} },
  URL: { createObjectURL: () => "blob:" }, Blob: class {}, Int16Array, Float32Array, Uint8Array, Math, JSON, Date, Promise,
};
g.window = g;
const run = () => { while (timers.length) { timers.sort((a, b) => a.at - b.at); timers.shift().fn(); } };
new Function(...Object.keys(g), script)(...Object.values(g));
(async () => {
  run();
  const tap = () => (handlers["talk:click"] || []).forEach(fn => fn({ preventDefault() {} }));
  tap();                                   // start a conversation
  await new Promise(r => setImmediate(r)); run();
  const during = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length };
  tap();                                   // end it
  run();                                   // the end chime rings out, then the page lets go
  const after = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length };
  console.log(JSON.stringify({ atLoad: audioSessionTypes[0], during, after }));
})();
