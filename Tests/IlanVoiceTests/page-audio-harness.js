// Runs the iPhone page's script against fake browser objects and reports how it
// uses the phone's audio across a conversation, and what it does when the
// connection to the Mac drops. Prints one JSON line.
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
const intervals = [];
const contexts = [];
// Time on the harness's own timers (ms); run() moves it forward.
let now = 0;
// Like iOS: changing the audio session moves the sound to another route,
// which takes ROUTE_MS; meanwhile audio contexts are paused ("interrupted")
// and their clock stops. A context made during the move starts paused too.
const ROUTE_MS = 250;
let routeSettlesAt = 0;
class FakeAudioContext {
  constructor() { this.state = "interrupted"; this.closed = false; this.clock = 0; this.since = null; this.sampleRate = 48000;
    this.destination = any(); this.audioWorklet = { addModule: async () => {} }; contexts.push(this); this.settle(); }
  get currentTime() { return (this.clock + (this.since === null ? 0 : now - this.since)) / 1000; }
  settle() { if (now >= routeSettlesAt) this.play(); else g.setTimeout(() => this.settle(), routeSettlesAt - now); }
  play() { if (this.closed || this.since !== null) return; this.state = "running"; this.since = now; this.onstatechange && this.onstatechange(); }
  pause() { if (this.closed || this.since === null) return; this.clock += now - this.since; this.since = null; this.state = "interrupted";
    this.onstatechange && this.onstatechange(); this.settle(); }
  resume() { if (!this.closed && this.since === null) this.settle(); return Promise.resolve(); }
  close() { this.pause(); this.closed = true; this.state = "closed"; return Promise.resolve(); }
  // Each start/end sound: the session it played in, and how long the context
  // had been playing steadily when it started (-1: paused, i.e. garbled on iOS).
  createOscillator() { g.oscillators = (g.oscillators || 0) + 1; chimeSessions.add(audioSessionTypes.at(-1));
    if (sounds.at(-1)?.at !== now) {
      // The inaudible hum warming the speaker up: still on, or stopped just as the sound starts.
      const hum = hums.filter(h => h.context === this && (h.on || h.stoppedAt === now)).at(-1);
      sounds.push({ at: now, steadyMs: this.since === null ? -1 : now - this.since, humMs: hum ? now - hum.startedAt : -1, hum });
    }
    return any(); }
  createGain() { return any(); } createDynamicsCompressor() { return any(); } createBiquadFilter() { return any(); }
  createDelay() { return any(); } createBuffer() { return { getChannelData: () => new Float32Array(1), duration: 0 }; }
  // A looping buffer source is the page's warm-up hum: when it starts and stops is kept.
  createBufferSource() { const src = { context: this, loop: false, on: false, connect() {}, disconnect() {},
    start() { src.startedAt = now; src.on = true; if (src.loop) hums.push(src); }, stop() { if (src.on) { src.on = false; src.stoppedAt = now; } } }; return src; }  // (a second stop() changes nothing)
  createMediaStreamSource() { return any(); } createAnalyser() { return any(); }
}
const sent = [];
const audioSessionTypes = [];
const chimeSessions = new Set();  // the audio session each start/end sound played in
const sounds = [];
const hums = [];
const wakeLocks = [];
const g = {
  window: null, console,
  document: { getElementById: el, querySelector: () => el("q"), createElement: () => el("x" + Math.random()),
              body: el("body"), documentElement: el("html"), addEventListener() {}, hidden: false },
  // An upright iPhone (393 x 852 pt) whose home-screen page is 62 pt short.
  screen: { width: 393, height: 852 }, innerWidth: 393, innerHeight: 790, visualViewport: { height: 790 },
  matchMedia: () => ({ matches: true }),
  // window events (e.g. "online"), so tests can fire them
  addEventListener(type, fn) { (handlers["window:" + type] = handlers["window:" + type] || []).push(fn); },
  getComputedStyle: () => ({ paddingTop: "62px", paddingBottom: "34px" }),
  navigator: { standalone: true, wakeLock: { request: async type => { const l = { type, released: false, release: async () => { l.released = true; } };
                                                    wakeLocks.push(l); return l; } },
               audioSession: { set type(v) { if (audioSessionTypes.length && v !== audioSessionTypes.at(-1)) {
                                  routeSettlesAt = now + ROUTE_MS; contexts.forEach(c => c.pause()); }
                                audioSessionTypes.push(v); },
                              get type() { return audioSessionTypes.at(-1); }, },
               mediaDevices: { getUserMedia: async () => { g.micAsks = (g.micAsks || 0) + 1; g.micAt = now;
                 const track = { label: "Car Hands-Free", getSettings: () => ({ sampleRate: 16000, echoCancellation: true }),
                                 stop() { g.micStops = (g.micStops || 0) + 1; } };
                 return { getTracks: () => [track], getAudioTracks: () => [track] }; } } },
  localStorage: { getItem: k => (k === "ilanToken" ? "t" : k === "ilanDevice" ? "d" : null), setItem() {}, removeItem() {} },
  location: { protocol: "https:", host: "h", search: "" }, URLSearchParams: class { get() { return null; } },
  // Opens, and answers the page's hello the way the Mac does: hello_ok saying
  // whether the Mac still has a conversation (g.macConversing), then its state.
  // With g.stallNext > 0 the next connection never opens. (On the harness's
  // own timers, so it opens when run() drains them.)
  WebSocket: class { constructor() { g.sockets = (g.sockets || 0) + 1; g.socket = this; this.closed = false;
                       if (g.stallNext > 0) { g.stallNext--; this.readyState = 0; return; }
                       this.readyState = 1; g.setTimeout(() => this.onopen && this.onopen(), 0); }
                     // Everything sent, in order (g.wire: JSON objects, and audio as its byte count).
                     send(m) {
                       if (typeof m !== "string") { (g.wire = g.wire || []).push(m.byteLength); return; }
                       sent.push(m); (g.wire = g.wire || []).push(JSON.parse(m));
                       if (m.includes('"hello"')) g.setTimeout(() => {
                         if (!this.onmessage) return;
                         const ok = { type: "hello_ok", conversing: !!g.macConversing };
                         if (g.macMicReceived !== undefined) ok.micReceived = g.macMicReceived;  // how much mic audio the Mac got
                         this.onmessage({ data: JSON.stringify(ok) });
                         this.onmessage({ data: JSON.stringify({ type: "state", phase: g.macConversing ? "Listening" : "Ready", busy: false }) });
                       }, 0); }
                     close() { this.closed = true; this.readyState = 3; } },
  AudioContext: FakeAudioContext, AudioWorkletNode: class { constructor() { this.port = {}; (g.workletNodes = g.workletNodes || []).push(this); } connect() {} disconnect() {} },
  setTimeout: (fn, ms) => { timers.push({ fn, at: now + (ms || 0) }); return timers.length; }, clearTimeout() {},
  setInterval: fn => { intervals.push(fn); return intervals.length; }, requestAnimationFrame() {}, ResizeObserver: class { observe() {} },
  // The page's clock; tests move it forward with g.skew (ms).
  Date: class extends Date { static now() { return Date.now() + (g.skew || 0); } },
  URL: { createObjectURL: () => "blob:" }, Blob: class {}, Int16Array, Float32Array, Uint8Array, Math, JSON, Promise,
};
g.window = g;
// Runs every pending timer, earliest first, moving the clock to each, and
// lets the page's promises settle in between (its sounds wait on timers).
const flush = () => new Promise(r => setImmediate(r));
const run = async () => { await flush();
  while (timers.length) { timers.sort((a, b) => a.at - b.at); const t = timers.shift(); now = Math.max(now, t.at); t.fn(); await flush(); } };
const tick = () => intervals.forEach(fn => fn());  // the page's once-a-second checks
new Function(...Object.keys(g), script)(...Object.values(g));
(async () => {
  await run();
  const fire = (type, e) => (handlers["talk:" + type] || []).forEach(fn => fn({ preventDefault() {}, pointerId: 1, ...e }));
  // A real tap: finger down and up in place, then the click.
  const tap = () => { fire("pointerdown", { clientY: 500, timeStamp: 0 }); fire("pointerup", { clientY: 500, timeStamp: 80 }); fire("click", {}); };
  const settle = run;
  const conversing = () => el("body").classes.has("conversing");  // the page's own view
  const count = type => sent.filter(m => m.includes('"' + type + '"')).length;
  const lastHello = () => JSON.parse(sent.filter(m => m.includes('"hello"')).at(-1));
  const screenOn = () => wakeLocks.some(l => l.type === "screen" && !l.released);
  const chimes = () => g.oscillators || 0;
  // What the page reported to the Mac's log ("diag"), from the `from`th message sent on.
  const diags = (from = 0) => sent.slice(from).map(m => JSON.parse(m)).filter(m => m.type === "diag");
  // Press, push up `px` (drifting `side` px sideways at the end), let go. No holding.
  const push = (px, side = 0) => {
    fire("pointerdown", { clientX: 200, clientY: 500, timeStamp: 0 });
    fire("pointermove", { clientX: 200, clientY: 500 - px / 2, timeStamp: 40 });
    fire("pointermove", { clientX: 200 + side, clientY: 500 - px, timeStamp: 80 });
    fire("pointerup", { clientX: 200 + side, clientY: 500 - px, timeStamp: 100 });
  };
  // No microphone permission yet: the first tap only asks for it.
  const nomicAtLoad = el("talk").classes.has("nomic");
  const green = () => el("talk").classes.has("ready");
  const readyLook = { atLoad: green() };  // no microphone yet: not green
  tap(); await settle();
  const allowTap = { started: conversing(), asked: g.micAsks || 0, released: g.micStops || 0,
                     nomicAfter: el("talk").classes.has("nomic") };
  readyLook.micAllowed = green();  // microphone allowed, connected, no conversation: green
  const oscBeforeStart = chimes(), tapAt = now, sentBeforeStart = sent.length;
  tap();                                   // start a conversation (the second tap)
  const micBeforeStartSound = (g.micAsks || 0) > 1, toldMacAtTap = count("conversation_start") > 0;
  const hintAtTap = el("hint").textContent;
  readyLook.starting = green();  // the start sound is playing: red already
  await settle();
  // The sound waits for the loudspeaker; the mic opens, and the Mac hears of it, only once the sound is over.
  const startSound = { chimed: chimes() > oscBeforeStart, micBefore: micBeforeStartSound, toldMacAtTap, hintAtTap,
                       soundAfterMs: sounds.at(-1).at - tapAt, steadyMs: sounds.at(-1).steadyMs,
                       micAfterMs: (g.micAsks || 0) === 2 ? g.micAt - tapAt : -1, toldMac: count("conversation_start") === 1 };
  readyLook.conversing = green();
  // The page's report of the start: each step in order, the audio pausing as iOS
  // switches routes, and which microphone it got.
  const startDiags = diags(sentBeforeStart);
  const startReport = { steps: startDiags.map(d => d.what).filter(w => !w.startsWith("audio ")),
                        audio: startDiags.filter(d => d.what.startsWith("audio ")).length,
                        mic: startDiags.find(d => d.what === "microphone on"),
                        sound: startDiags.find(d => d.what === "start sound done") };
  const during = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length,
                   screenKeptOn: screenOn() };

  // ---- The connection drops mid-conversation ----
  // iOS reports the close. The conversation waits: mic and screen kept, "Reconnecting…".
  let micStops = g.micStops || 0, osc = chimes(), starts = count("conversation_start"), stops = count("conversation_stop"), sockets = g.sockets;
  g.socket.onclose();
  const whileAway = { conversing: conversing(), micKept: (g.micStops || 0) === micStops, screenKeptOn: screenOn(),
                      away: el("body").classes.has("away"), hint: el("hint").textContent, status: el("status").textContent };
  // The retry connects; the Mac still has the conversation: it carries on, nothing restarted, no sound.
  g.macConversing = true; await run();
  const resumed = { drop: lastHello().drop, helloConversing: lastHello().conversing, conversing: conversing(), restarted: count("conversation_start") > starts,
                    chimed: chimes() > osc, away: el("body").classes.has("away"), hint: el("hint").textContent,
                    status: el("status").textContent, micAsks: g.micAsks || 0, reconnected: g.sockets > sockets };
  // It drops again, and now the Mac has let the conversation go (too long away,
  // or Ilan ended it): this side ends too, with the closing sound, without a stop.
  g.socket.onclose(); osc = chimes(); stops = count("conversation_stop");
  g.macConversing = false; await run();
  const letGo = { conversing: conversing(), chimed: chimes() > osc, sentStop: count("conversation_stop") > stops,
                  screenKeptOn: screenOn(), session: audioSessionTypes.at(-1), away: el("body").classes.has("away") };
  // Ended by the user while away: the end gesture works without the Mac, which learns from the next hello.
  tap(); await settle();
  g.socket.onclose(); stops = count("conversation_stop"); osc = chimes();
  let soundsBefore = sounds.length;
  push(170);
  const endedAway = { conversing: conversing(), sentStop: count("conversation_stop") > stops };
  const sentWhileAway = sent.length;
  g.skew = (g.skew || 0) + 5000;  // 5 s offline
  await run();  // the end sound plays; the page reconnects
  endedAway.helloConversing = lastHello().conversing; endedAway.sounds = sounds.length - soundsBefore;
  // What the page did while away is reported once the Mac is back (after its hello), with how long ago.
  const awayMsgs = sent.slice(sentWhileAway).map(m => JSON.parse(m));
  const endedDiag = awayMsgs.findIndex(m => m.type === "diag" && m.what === "conversation ended");
  endedAway.report = { afterHello: endedDiag > awayMsgs.findIndex(m => m.type === "hello"), agoMs: awayMsgs[endedDiag] && awayMsgs[endedDiag].agoMs,
                       once: diags().filter(d => d.what === "conversation ended" && d.byIlan === false).length };

  // ---- Silence ----
  // The Mac's pings are answered. A stall of several seconds is ridden out
  // (the network often delivers late); a connection with nothing heard for
  // 15 s is given up on and replaced.
  g.socket.onmessage({ data: JSON.stringify({ type: "ping" }) });
  const ponged = sent.at(-1) === JSON.stringify({ type: "pong" });
  const stale = g.socket; sockets = g.sockets;
  g.skew = (g.skew || 0) + 7000; tick();
  const rodeOut = !stale.closed && el("status").textContent !== "Reconnecting…";
  g.skew += 9000; tick();
  const silence = { ponged, rodeOut, abandoned: stale.closed, status: el("status").textContent };
  readyLook.reconnecting = green();  // no connection: not green
  await run();
  silence.reconnected = g.sockets > sockets && g.socket !== stale;
  silence.drop = lastHello().drop;
  // iOS says the network is back: a connection quiet for more than one ping
  // is given up on at once, but not one heard from a moment ago.
  const fireWindow = (type) => (handlers["window:" + type] || []).forEach(fn => fn());
  const live = g.socket; sockets = g.sockets;
  g.skew += 1000; fireWindow("online");
  silence.keptWhenFresh = !live.closed && g.sockets === sockets;
  g.skew += 3000; fireWindow("online");
  silence.droppedWhenQuiet = live.closed;
  await run();
  silence.reasonWhenQuiet = lastHello().drop && lastHello().drop.reason;
  readyLook.reconnected = green();  // connected again: green

  // ---- Away too long ----
  // No Mac for over AWAY_LIMIT_MS: the page lets the conversation go itself.
  tap(); await settle();
  g.socket.onclose(); osc = chimes();
  g.skew += 151000; tick();
  const tooLong = { conversing: conversing(), banner: el("banner").textContent };
  await run();  // the end sound plays; reconnects, idle
  tooLong.chimed = chimes() > osc;

  // ---- Replaced ----
  // Another window on this phone took over: this one ends its conversation and stops retrying.
  g.macConversing = true; tap(); await settle();
  g.socket.onmessage({ data: JSON.stringify({ type: "replaced" }) }); g.socket.onclose();
  sockets = g.sockets; await run();
  const replaced = { conversing: conversing(), retried: g.sockets > sockets, status: el("status").textContent };
  // Tapping the banner brings this window back.
  g.macConversing = false; (handlers["banner:click"] || []).forEach(fn => fn()); await run();
  replaced.backAfterTap = g.sockets > sockets;

  // ---- A connection that never opens ----
  // Given up on after CONNECT_TIMEOUT_MS; the next try opens.
  g.socket.onclose(); g.stallNext = 1; sockets = g.sockets; await run();
  const stalled = { tries: g.sockets - sockets, status: el("status").textContent };

  // Ended during the start sound: the Mac never hears of the conversation, no mic opens.
  g.macConversing = false; let starts0 = count("conversation_start"), stops0 = count("conversation_stop"), asks0 = g.micAsks;
  tap(); push(170); await run();
  const endedWhileStarting = { told: count("conversation_start") - starts0 + count("conversation_stop") - stops0,
                               micAsks: g.micAsks - asks0, conversing: conversing() };
  // Started, ended and started again quickly: only the second one starts (once).
  starts0 = count("conversation_start"); asks0 = g.micAsks;
  tap(); push(170); tap(); await run();
  const quickRestart = { starts: count("conversation_start") - starts0, micAsks: g.micAsks - asks0, conversing: conversing() };
  push(170); await run();
  // Pocket mode: only pushing the button all the way up the track ends it (no holding).
  g.macConversing = true; tap(); await settle();
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
  await run();                                   // the end chime rings out, then the page lets go
  // Ilan ends a conversation itself (its end_conversation tool): the Mac tells the page.
  tap(); await settle();
  const stopsBefore = count("conversation_stop"), oscBefore = chimes();
  g.socket.onmessage({ data: JSON.stringify({ type: "conversation_ended" }) });
  await run();
  const endedByIlan = { conversing: conversing(),
                        sentStop: count("conversation_stop") > stopsBefore,
                        chimed: chimes() > oscBefore, session: audioSessionTypes.at(-1),
                        screenKeptOn: wakeLocks.some(l => !l.released) };
  const after = { session: audioSessionTypes.at(-1), openContexts: contexts.filter(c => !c.closed).length,
                  screenKeptOn: wakeLocks.some(l => !l.released) };
  const viewport = sent.map(m => { try { return JSON.parse(m); } catch (e) { return {}; } }).find(m => m.type === "viewport");
  const shortPage = el("html").classes.has("short-page");
  // ---- Nothing lost on a bad network ----
  g.macConversing = false; g.macMicReceived = undefined;
  tap(); await settle();                                     // a conversation, the mic on
  const node = g.workletNodes.at(-1);
  const chunk = () => node.port.onmessage({ data: new Float32Array(960).fill(0.25) });  // 20 ms at 48 kHz: 960 bytes at 24 kHz
  const bytes = list => list.filter(x => typeof x === "number");
  g.wire = [];
  chunk(); chunk();                                          // live: sent as recorded
  const nothingLost = { liveBytes: bytes(g.wire).reduce((a, b) => a + b, 0) };
  g.socket.onmessage({ data: JSON.stringify({ type: "reply", item: "a1", at: 0 }) });  // Ilan's reply: which, from where
  g.socket.onmessage({ data: new ArrayBuffer(4800) });
  g.socket.onmessage({ data: new ArrayBuffer(4800) });
  g.socket.onclose(); g.wire = [];                           // the connection drops...
  chunk(); chunk(); chunk();                                 // ...while three more pieces are recorded
  nothingLost.sentWhileAway = g.wire.length;
  // Back: the Mac got only the first live piece (the second went into a dead connection).
  g.macConversing = true; g.macMicReceived = 960;
  await run();
  const back = lastHello(), wire = g.wire;
  const iCatch = wire.findIndex(x => x && x.type === "catchup"), iEnd = wire.findIndex(x => x && x.type === "catchup_end");
  Object.assign(nothingLost, { micSent: back.micSent, playback: back.playback, catchup: wire[iCatch],
                               catchBytes: bytes(wire.slice(iCatch + 1, iEnd)), endAfter: iEnd > iCatch });
  chunk();                                                   // live again, after the catch-up
  nothingLost.liveAfter = typeof g.wire.at(-1) === "number" && g.wire.length - 1 > iEnd;
  // Ilan was stopped: the page has no reply to report any more.
  g.socket.onmessage({ data: JSON.stringify({ type: "audio_stop" }) });
  g.socket.onclose(); g.macMicReceived = undefined; await run();
  nothingLost.afterStop = lastHello().playback;
  // At most a minute is kept: what is older is reported lost.
  g.socket.onclose();
  for (let i = 0; i < 3010; i++) chunk();
  g.macMicReceived = 960; g.wire = [];
  await run();
  const cap = g.wire.find(x => x && x.type === "catchup");
  nothingLost.capped = { bytes: cap && cap.bytes, lost: cap && cap.lost, micSent: lastHello().micSent };
  push(170); await run();                                    // end it

  console.log(JSON.stringify({ startReport, nothingLost, nomicAtLoad, readyLook, allowTap, startSound, chimeSessions: [...chimeSessions], soundSteadyMs: sounds.map(x => x.steadyMs), soundHumMs: sounds.map(x => x.humMs), humsLeftOn: hums.filter(h => h.on).length,
    humAfterSoundMs: sounds.map(x => x.hum && x.hum.stoppedAt !== undefined ? x.hum.stoppedAt - x.at : -1),
    endedWhileStarting, quickRestart, endedByIlan, atLoad: audioSessionTypes[0], during, after, shortPage, gapVar: cssVars["--gap"], viewport,
    pocket: { afterStrayTap, afterShortPush, afterSmallPush, afterDrift, afterEndGesture },
    whileAway, resumed, letGo, endedAway, silence, tooLong, replaced, stalled }));
})();
