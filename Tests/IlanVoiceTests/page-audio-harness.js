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
const cssVars = {};
const el = id => elements[id] || (elements[id] = new Proxy({ id, style: { setProperty(k, v) { cssVars[k] = v; } }, classes: new Set(),
  get classList() { const c = this.classes; return { add: (...n) => n.forEach(x => c.add(x)), remove: (...n) => n.forEach(x => c.delete(x)),
                    toggle: (n, on) => { if (on === undefined ? !c.has(n) : on) c.add(n); else c.delete(n); }, contains: n => c.has(n) }; },
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
  createOscillator() { g.oscillators = (g.oscillators || 0) + 1; chimeSessions.add(audioSessionTypes.at(-1)); return any(); } createGain() { return any(); } createDynamicsCompressor() { return any(); }
  createDelay() { return any(); } createBuffer() { return { getChannelData: () => new Float32Array(1), duration: 0 }; }
  createBufferSource() { return any(); } createMediaStreamSource() { return any(); } createAnalyser() { return any(); }
}
const sent = [];
const audioSessionTypes = [];
const chimeSessions = new Set();  // the audio session each start/end sound played in
const wakeLocks = [];
const g = {
  window: null, console,
  document: { getElementById: el, querySelector: () => el("q"), createElement: () => el("x" + Math.random()),
              body: el("body"), documentElement: el("html"), addEventListener() {}, hidden: false },
  // An upright iPhone (393 x 852 pt) whose home-screen page is 62 pt short.
  screen: { width: 393, height: 852 }, innerWidth: 393, innerHeight: 790, visualViewport: { height: 790 },
  matchMedia: () => ({ matches: true }),
  addEventListener() {},
  getComputedStyle: () => ({ paddingTop: "62px", paddingBottom: "34px" }),
  navigator: { standalone: true, wakeLock: { request: async type => { const l = { type, released: false, release: async () => { l.released = true; } };
                                                    wakeLocks.push(l); return l; } },
               audioSession: { set type(v) { audioSessionTypes.push(v); }, get type() { return audioSessionTypes.at(-1); } },
               mediaDevices: { getUserMedia: async () => { g.micAsks = (g.micAsks || 0) + 1; g.micDelayMs = g.timerMs;
                 return { getTracks: () => [{ stop() { g.micStops = (g.micStops || 0) + 1; } }] }; } } },
  localStorage: { getItem: k => (k === "ilanToken" ? "t" : k === "ilanDevice" ? "d" : null), setItem() {}, removeItem() {} },
  location: { protocol: "https:", host: "h", search: "" }, URLSearchParams: class { get() { return null; } },
  // Opens, and answers the page's hello the way the Mac does.
  // (On the harness's own timers, so it opens when run() drains them.)
  WebSocket: class { constructor() { this.readyState = 1; g.socket = this; g.setTimeout(() => this.onopen && this.onopen(), 0); }
                     send(m) { sent.push(m);
                       if (m.includes('"hello"')) g.setTimeout(() => this.onmessage && this.onmessage({ data: JSON.stringify({ type: "hello_ok" }) }), 0); }
                     close() {} },
  AudioContext: FakeAudioContext, AudioWorkletNode: class { constructor() { this.port = {}; } connect() {} disconnect() {} },
  setTimeout: (fn, ms) => { timers.push({ fn, at: (ms || 0) }); return timers.length; }, clearTimeout() {},
  setInterval: () => 0, requestAnimationFrame() {}, ResizeObserver: class { observe() {} },
  URL: { createObjectURL: () => "blob:" }, Blob: class {}, Int16Array, Float32Array, Uint8Array, Math, JSON, Date, Promise,
};
g.window = g;
// Runs every pending timer, earliest first; g.timerMs is the delay of the one running.
const run = () => { while (timers.length) { timers.sort((a, b) => a.at - b.at); const t = timers.shift(); g.timerMs = t.at; t.fn(); g.timerMs = 0; } };
new Function(...Object.keys(g), script)(...Object.values(g));
(async () => {
  run();
  const fire = (type, e) => (handlers["talk:" + type] || []).forEach(fn => fn({ preventDefault() {}, pointerId: 1, ...e }));
  // A real tap: finger down and up in place, then the click.
  const tap = () => { fire("pointerdown", { clientY: 500, timeStamp: 0 }); fire("pointerup", { clientY: 500, timeStamp: 80 }); fire("click", {}); };
  const conversing = () => sent.filter(m => m.includes("conversation_start")).length > sent.filter(m => m.includes("conversation_stop")).length;
  // Press, push up `px` (drifting `side` px sideways at the end), let go. No holding.
  const push = (px, side = 0) => {
    fire("pointerdown", { clientX: 200, clientY: 500, timeStamp: 0 });
    fire("pointermove", { clientX: 200, clientY: 500 - px / 2, timeStamp: 40 });
    fire("pointermove", { clientX: 200 + side, clientY: 500 - px, timeStamp: 80 });
    fire("pointerup", { clientX: 200 + side, clientY: 500 - px, timeStamp: 100 });
  };
  // No microphone permission yet: the first tap only asks for it.
  const nomicAtLoad = el("talk").classes.has("nomic");
  tap(); await new Promise(r => setImmediate(r)); run();
  const allowTap = { started: conversing(), asked: g.micAsks || 0, released: g.micStops || 0,
                     nomicAfter: el("talk").classes.has("nomic") };
  const oscBeforeStart = g.oscillators || 0;
  tap();                                   // start a conversation (the second tap)
  const micBeforeStartSound = (g.micAsks || 0) > 1;
  await new Promise(r => setImmediate(r)); run(); await new Promise(r => setImmediate(r));
  const startSound = { chimed: (g.oscillators || 0) > oscBeforeStart, micBefore: micBeforeStartSound,
                       micAfterMs: (g.micAsks || 0) === 2 ? g.micDelayMs : -1 };
  const during = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length,
                   screenKeptOn: wakeLocks.some(l => l.type === "screen" && !l.released) };
  tap();                                   // a stray touch (e.g. in a pocket)
  const afterStrayTap = conversing();
  push(120);                               // a flick up, short of the End target
  const afterShortPush = conversing();
  push(40);                                // a small push
  const afterSmallPush = conversing();
  push(140, 100);                          // pushed up but drifted well off the track
  const afterDrift = conversing();
  push(170);                               // the real gesture: push all the way up, let go
  const afterEndGesture = conversing();
  run();                                   // the end chime rings out, then the page lets go
  // Ilan ends a conversation itself (its end_conversation tool): the Mac tells the page.
  tap(); await new Promise(r => setImmediate(r)); run();
  const stopsBefore = sent.filter(m => m.includes("conversation_stop")).length, oscBefore = g.oscillators || 0;
  g.socket.onmessage({ data: JSON.stringify({ type: "conversation_ended" }) });
  run();
  const endedByIlan = { conversing: conversing() && sent.filter(m => m.includes("conversation_stop")).length === stopsBefore,
                        sentStop: sent.filter(m => m.includes("conversation_stop")).length > stopsBefore,
                        chimed: (g.oscillators || 0) > oscBefore, session: audioSessionTypes.at(-1),
                        screenKeptOn: wakeLocks.some(l => !l.released) };
  const after = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length,
                  screenKeptOn: wakeLocks.some(l => !l.released) };
  const viewport = sent.map(m => { try { return JSON.parse(m); } catch (e) { return {}; } }).find(m => m.type === "viewport");
  const shortPage = el("html").classes.has("short-page");
  console.log(JSON.stringify({ nomicAtLoad, allowTap, startSound, chimeSessions: [...chimeSessions], endedByIlan, atLoad: audioSessionTypes[0], during, after, shortPage, gapVar: cssVars["--gap"], viewport,
    pocket: { afterStrayTap, afterShortPush, afterSmallPush, afterDrift, afterEndGesture } }));
})();
