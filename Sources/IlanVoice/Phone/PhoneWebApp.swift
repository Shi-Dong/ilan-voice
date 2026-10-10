// The iPhone web app, served by PhoneServer. One page, no build step.
//
// Talking: hold the round button to record (24 kHz PCM16 is streamed to the
// Mac while it is held), let go to send. Replies stream back as PCM16 and
// play straight away. The Mac does everything else: transcription, the model,
// tools, saving the conversation.
enum PhoneWebApp {
    static let manifest = """
    {
      "name": "Ilan Voice",
      "short_name": "Ilan",
      "display": "standalone",
      "background_color": "#0E1213",
      "theme_color": "#161D1C",
      "icons": [
        { "src": "/icon-180.png", "sizes": "180x180", "type": "image/png" },
        { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
      ]
    }
    """

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <!-- An opaque status bar: the page starts below it. With a translucent bar
         the page ran underneath the clock and battery, where iOS lays its own
         blurred fade that a page cannot remove. -->
    <meta name="apple-mobile-web-app-status-bar-style" content="black">
    <meta name="apple-mobile-web-app-title" content="Ilan">
    <meta name="theme-color" content="#161D1C">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon-180.png">
    <title>Ilan Voice</title>
    <style>
      :root {
        --ink: #0E1213; --raised: #161D1C; --card: rgba(255,255,255,.055); --hair: rgba(255,255,255,.08);
        --text: #E9EFED; --dim: rgba(255,255,255,.55); --mint: #A9DCCB; --mint-deep: #4DA88F; --orange: #F28C2A; --red: #FF6B6B;
      }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      html, body { margin: 0; height: 100%; background: var(--ink); color: var(--text);
        font: 16px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
      /* The page runs full-screen under the iPhone's status bar (clock,
         battery). Its height follows the real visible screen (100dvh; iOS
         home-screen apps get 100% wrong), and the header is solid and starts
         at the very top, so the status bar sits on a crisp, even band rather
         than on the soft background gradient. */
      body { display: flex; flex-direction: column; overflow: hidden; height: 100vh; height: 100dvh;
        background: radial-gradient(120% 60% at 50% 30%, #15211F 0%, var(--ink) 60%); }
      header { padding: calc(env(safe-area-inset-top) + 12px) 20px 12px; display: flex; align-items: center; gap: 12px;
        flex: none; position: relative; z-index: 2; background: var(--raised);
        border-bottom: 1px solid var(--hair); box-shadow: 0 6px 18px rgba(0,0,0,.25); }
      header img { width: 34px; height: 34px; border-radius: 9px; flex: none; }
      /* The title clips long names with "…", so its box hides overflow. Its
         height is whole pixels with room above and below the letters
         (24 px line + 2 px padding each side), so the clip never cuts
         through the top of a letter, which looked like a blurred top edge. */
      header .title { font-weight: 600; font-size: 17px; line-height: 24px; padding: 2px 0; margin: -2px 0;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      header .status { font-size: 12.5px; color: var(--dim); display: flex; align-items: center; gap: 6px; }
      #reconnect { margin-left: auto; flex: none; width: 36px; height: 36px; border-radius: 50%; border: 1px solid var(--hair);
        background: var(--card); color: var(--dim); display: flex; align-items: center; justify-content: center; }
      #reconnect svg { width: 17px; height: 17px; transition: transform .6s ease; }
      #reconnect.spin svg { transform: rotate(360deg); }
      .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--dim); flex: none; }
      .dot.ok { background: var(--mint); } .dot.busy { background: var(--orange); } .dot.rec { background: var(--red); }
      main { flex: 1; overflow-y: auto; padding: 16px 16px 24px; display: flex; flex-direction: column; gap: 10px;
        -webkit-overflow-scrolling: touch; }
      .empty { margin: auto; text-align: center; color: var(--dim); font-size: 15px; padding: 0 30px; }
      .empty b { display: block; color: var(--text); font-size: 20px; margin-bottom: 6px; }
      .msg { max-width: 84%; padding: 9px 13px; border-radius: 17px; font-size: 15.5px; white-space: pre-wrap; word-wrap: break-word; }
      .msg.user { align-self: flex-end; background: var(--mint-deep); color: #06120F; border-bottom-right-radius: 5px; }
      .msg.assistant { align-self: flex-start; background: var(--card); border: 1px solid var(--hair); border-bottom-left-radius: 5px; }
      .msg.tool { align-self: flex-start; font-size: 12.5px; color: var(--dim); padding: 2px 6px; }
      .msg.pending { opacity: .6; }
      footer { padding: 8px 24px max(10px, calc(env(safe-area-inset-bottom) - 8px)); display: grid;
        grid-template-columns: 1fr auto 1fr; align-items: center; border-top: 1px solid var(--hair); background: rgba(14,18,19,.85); }
      .hint { grid-column: 1 / -1; text-align: center; font-size: 12.5px; color: var(--dim); margin-bottom: 6px; min-height: 17px; }
      .side { width: 52px; height: 52px; border-radius: 50%; border: 1px solid var(--hair); background: var(--card); color: var(--text);
        display: flex; align-items: center; justify-content: center; justify-self: start; }
      .side:disabled { opacity: .35; }
      .side svg { width: 22px; height: 22px; }
      #talk { width: 96px; height: 96px; border-radius: 50%; border: none; position: relative; touch-action: none;
        -webkit-user-select: none; user-select: none; -webkit-touch-callout: none;
        background: radial-gradient(circle at 35% 30%, #CFF0E4, var(--mint) 45%, var(--mint-deep));
        box-shadow: 0 0 0 6px rgba(169,220,203,.12), 0 10px 30px rgba(77,168,143,.35); transition: transform .12s; }
      #talk svg { width: 38px; height: 38px; color: #0B1F19; }
      #talk.held { transform: scale(1.08); background: radial-gradient(circle at 35% 30%, #FFC9C9, var(--red) 55%, #C94444);
        box-shadow: 0 10px 30px rgba(255,107,107,.35); }
      /* The voice halo: a canvas behind the button, drawn every frame from the
         microphone's live spectrum (see "Voice halo" in the script). */
      .talkwrap { position: relative; width: 96px; height: 96px; }
      .talkwrap #talk { z-index: 1; }
      #halo { position: absolute; left: 50%; top: 50%; width: 240px; height: 240px; margin: -120px 0 0 -120px;
        pointer-events: none; z-index: 0; }
      #talk.held svg { color: #2A0B0B; }
      /* Swiped up far enough: letting go now cancels. */
      #talk.held.cancel { transform: scale(0.92); background: radial-gradient(circle at 35% 30%, #d9dedd, #8b9593 60%, #5f6866);
        box-shadow: 0 10px 30px rgba(0,0,0,.35); }
      #talk.held.cancel svg { color: #1c2221; }
      .hint.cancel { color: var(--red); font-weight: 600; }
      #talk:disabled { filter: grayscale(1) brightness(.6); }
      .sheet { position: fixed; inset: 0; background: rgba(5,8,8,.72); display: none; align-items: flex-end; z-index: 5;
        -webkit-backdrop-filter: blur(6px); backdrop-filter: blur(6px); }
      .sheet.open { display: flex; }
      .sheet .panel { width: 100%; background: var(--raised); border-top: 1px solid var(--hair); border-radius: 22px 22px 0 0;
        padding: 22px 18px calc(env(safe-area-inset-bottom) + 18px); }
      .sheet h2 { margin: 0 0 4px; font-size: 19px; }
      .sheet p { margin: 0 0 16px; color: var(--dim); font-size: 14px; }
      .choice { width: 100%; text-align: left; border: 1px solid var(--hair); background: var(--card); color: var(--text);
        border-radius: 14px; padding: 12px 14px; margin-bottom: 9px; font: inherit; display: flex; align-items: center; gap: 12px; }
      .choice .nm { font-weight: 600; }
      .choice .sub { color: var(--dim); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .choice.new { border-style: dashed; color: var(--mint); justify-content: center; font-weight: 600; }
      .banner { margin: 10px 16px 0; padding: 9px 12px; border-radius: 10px; font-size: 13.5px;
        background: rgba(242,140,42,.14); color: var(--orange); display: none; }
    </style>
    </head>
    <body>
    <header>
      <img src="/icon-180.png" alt="">
      <div style="min-width:0">
        <div class="title" id="title">Ilan Voice</div>
        <div class="status"><span class="dot" id="dot"></span><span id="status">Connecting…</span></div>
      </div>
      <button id="reconnect" aria-label="Reconnect">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M20 12a8 8 0 1 1-2.34-5.66"/><path d="M20 4v5h-5"/></svg>
      </button>
    </header>
    <div class="banner" id="banner"></div>
    <div class="sheet" id="sheet"><div class="panel">
      <h2>Which iPhone is this?</h2>
      <p>Pick it to carry on with its conversation, for example after adding Ilan to the home screen again.</p>
      <div id="phones"></div>
      <button class="choice new" id="newPhone">This is a new iPhone</button>
    </div></div>
    <main id="list"><div class="empty"><b>Hold to talk</b>Let go to send. Ilan answers out loud.</div></main>
    <footer>
      <div class="hint" id="hint">Hold the button and speak</div>
      <button class="side" id="replay" aria-label="Replay last reply" disabled>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/></svg>
      </button>
      <div class="talkwrap"><canvas id="halo"></canvas>
      <button id="talk" aria-label="Hold to talk">
        <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 15a3.5 3.5 0 0 0 3.5-3.5v-6a3.5 3.5 0 1 0-7 0v6A3.5 3.5 0 0 0 12 15Z"/>
          <path d="M18.5 11.5a.9.9 0 1 0-1.8 0 4.7 4.7 0 0 1-9.4 0 .9.9 0 1 0-1.8 0 6.5 6.5 0 0 0 5.6 6.4V20H8.8a.9.9 0 1 0 0 1.8h6.4a.9.9 0 1 0 0-1.8H12.9v-2.1a6.5 6.5 0 0 0 5.6-6.4Z"/></svg>
      </button></div>
      <span></span>
    </footer>
    <script>
    "use strict";
    const RATE = 24000, PREBUFFER = 0.3;
    const $ = id => document.getElementById(id);
    const params = new URLSearchParams(location.search);
    const token = params.get("t") || localStorage.getItem("ilanToken") || "";
    if (params.get("t")) localStorage.setItem("ilanToken", params.get("t"));
    // Tells this phone apart from others, so each gets its own conversation.
    let device = localStorage.getItem("ilanDevice");
    if (!device) {
      device = Array.from(crypto.getRandomValues(new Uint8Array(12)), b => b.toString(16).padStart(2, "0")).join("");
      localStorage.setItem("ilanDevice", device);
    }
    let replaced = false;

    let ws = null, ctx = null, playHead = 0, sources = [], hasReply = false;
    let micStream = null, micNode = null, micSource = null, held = false, sending = false, phase = "Offline";

    // ---- Connection ----
    function connect() {
      if (!token) { banner("Open the link shown in Ilan Voice on your Mac (Settings → General → iPhone)."); return; }
      ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
      ws.binaryType = "arraybuffer";
      ws.onopen = () => ws.send(JSON.stringify({ type: "hello", token, device }));
      ws.onmessage = e => typeof e.data === "string" ? onJSON(JSON.parse(e.data)) : playPCM(e.data);
      ws.onclose = () => {
        ws = null;
        if (replaced) { setStatus("Open in another window", ""); return; }
        setStatus("Reconnecting…", ""); setTimeout(connect, 1500);
      };
    }
    function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

    function onJSON(m) {
      if (m.type === "hello_ok") { replaced = false; banner(""); }
      else if (m.type === "choose_phone") { choosePhone(m.phones); }
      else if (m.type === "replaced") { replaced = true;
        banner("Ilan was opened in another window on this phone. Tap here to use it in this one."); }
      else if (m.type === "auth_failed") { localStorage.removeItem("ilanToken");
        banner("This link is no longer paired. Open the current link from Ilan Voice on your Mac."); }
      else if (m.type === "state") {
        lastState = m;
        showState();
      }
      else if (m.type === "messages") { render(m); }
      else if (m.type === "audio_stop") { stopAudio(); }
    }

    // Taking over an earlier iPhone's ID resumes its conversation.
    function choosePhone(phones) {
      const list = $("phones"); list.innerHTML = "";
      for (const p of phones) {
        const b = document.createElement("button");
        b.className = "choice";
        const text = document.createElement("div"); text.style.minWidth = "0";
        const nm = document.createElement("div"); nm.className = "nm"; nm.textContent = p.name;
        const sub = document.createElement("div"); sub.className = "sub";
        sub.textContent = p.title ? p.title + (p.when ? " · " + p.when : "") : "No conversation yet";
        text.append(nm, sub); b.append(text);
        b.onclick = () => {
          localStorage.setItem("ilanDevice", p.device); device = p.device;
          $("sheet").classList.remove("open");
          if (ws) ws.close(); else connect();
        };
        list.appendChild(b);
      }
      $("newPhone").onclick = () => { send({ type: "new_phone" }); $("sheet").classList.remove("open"); };
      $("sheet").classList.add("open");
    }

    // ---- Microphone permission ----
    // "granted", "prompt" (not asked yet), "denied", or "unavailable" (no mic
    // API at all, e.g. not opened over https). When the mic isn't usable the
    // status says so instead of Ready, so it's clear why nothing will record.
    let micPermission = navigator.mediaDevices && navigator.mediaDevices.getUserMedia ? "prompt" : "unavailable";
    let lastState = null;
    if (navigator.permissions && navigator.permissions.query && micPermission !== "unavailable") {
      navigator.permissions.query({ name: "microphone" }).then(p => {
        micPermission = p.state; showState();
        p.onchange = () => { micPermission = p.state; showState(); };
      }).catch(() => {});
    }
    function showState() {
      const m = lastState;
      if (!m) return;
      phase = m.phase;
      const idle = !m.busy && m.phase !== "Listening";
      if (idle && micPermission === "denied") {
        setStatus("Microphone not allowed", "busy");
        $("hint").textContent = "Allow the microphone for this site in iOS Settings, then reopen";
      } else if (idle && micPermission === "unavailable") {
        setStatus("Microphone not available", "busy");
        $("hint").textContent = "Open the link from the Mac (https) to use the microphone";
      } else if (idle && micPermission === "prompt") {
        setStatus("Microphone not enabled yet", "busy");
        $("hint").textContent = "Hold the button and allow the microphone";
      } else {
        const cls = m.phase === "Listening" ? "rec" : m.busy ? "busy" : m.phase === "Offline" ? "" : "ok";
        setStatus(m.phase, cls);
        $("hint").textContent = held ? (cancelArmed ? "Release to cancel" : "Listening — let go to send · swipe up to cancel")
          : m.phase === "Speaking" ? "Tap to stop · hold to interrupt"
          : m.phase === "Thinking" || m.phase === "Using tools" ? m.phase + "…" : "Hold the button and speak";
      }
      if (m.error || !soundBanner) banner(m.error || "");
    }

    function setStatus(text, cls) { $("status").textContent = text; $("dot").className = "dot " + cls; }
    function banner(text) { const b = $("banner"); b.textContent = text; b.style.display = text ? "block" : "none"; }
    $("banner").addEventListener("click", () => {
      if (soundBanner) { soundBanner = false; audioContext(); banner(""); return; }
      if (replaced && !ws) { replaced = false; connect(); }
    });

    function render(m) {
      if (m.title) $("title").textContent = m.title;
      const list = $("list");
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
      list.innerHTML = "";
      if (!m.items.length) {
        list.innerHTML = '<div class="empty"><b>Hold to talk</b>Let go to send. Ilan answers out loud.</div>';
      }
      for (const it of m.items) {
        if (it.role === "user" && !it.text) continue;
        const d = document.createElement("div");
        d.className = "msg " + it.role + (it.pending ? " pending" : "");
        d.textContent = it.role === "tool" ? "⚙︎ " + it.text : (it.text || "…");
        list.appendChild(d);
      }
      hasReply = m.items.some(it => it.role === "assistant" && !it.pending);
      $("replay").disabled = !hasReply;
      if (atBottom || m.items.length) list.scrollTop = list.scrollHeight;
    }

    // ---- Audio routing ----
    // iOS sends sound to the quiet earpiece whenever a page's audio session
    // is in "play and record" mode, which is what using the microphone
    // switches it to. So: replies play from their own audio context with the
    // session set to "playback" (the loudspeaker); the microphone gets a
    // separate context that only exists while the button is held, and the
    // session goes back to "playback" as soon as it is closed.
    function setAudioSession(type) {
      try { if (navigator.audioSession) navigator.audioSession.type = type; } catch (e) {}
    }
    setAudioSession("playback");

    // ---- Playback ----
    // Switching the audio session for the microphone and back leaves the
    // playback context "interrupted" on iOS (not just "suspended"), and it
    // stays silent until it is resumed. So: resume whenever it isn't running,
    // after every press, and on every reply; and if iOS still won't let it
    // play, ask for one tap.
    function audioContext() {
      if (!ctx || ctx.state === "closed") {
        ctx = new (window.AudioContext || window.webkitAudioContext)();
        ctx.onstatechange = () => { if (ctx.state !== "running" && !held) ctx.resume().catch(() => {}); };
      }
      if (ctx.state !== "running") ctx.resume().catch(() => {});
      return ctx;
    }
    function needSoundTap() {
      if (soundBanner) return;
      soundBanner = true;
      banner("Tap here to turn on sound");
    }
    let soundBanner = false;
    function playPCM(buf) {
      const c = audioContext(), pcm = new Int16Array(buf);
      if (c.state !== "running") setTimeout(() => { if (c.state !== "running") needSoundTap(); }, 400);
      if (!pcm.length) return;
      const b = c.createBuffer(1, pcm.length, RATE), ch = b.getChannelData(0);
      for (let i = 0; i < pcm.length; i++) ch[i] = pcm[i] / 32768;
      const s = c.createBufferSource();
      s.buffer = b; s.connect(c.destination);
      if (playHead < c.currentTime) playHead = c.currentTime + PREBUFFER;
      s.start(playHead); playHead += b.duration;
      sources.push(s); s.onended = () => { sources = sources.filter(x => x !== s); };
    }
    function stopAudio() {
      for (const s of sources) { try { s.stop(); } catch (e) {} }
      sources = []; playHead = 0;
    }

    // ---- Recording ----
    const worklet = `class Tap extends AudioWorkletProcessor {
      process(inputs) { const ch = inputs[0][0]; if (ch) this.port.postMessage(ch.slice(0)); return true; } }
      registerProcessor("tap", Tap);`;
    const workletURL = URL.createObjectURL(new Blob([worklet], { type: "text/javascript" }));
    let micCtx = null;

    async function getMic(constraints) {
      try {
        const stream = await navigator.mediaDevices.getUserMedia(constraints);
        if (micPermission !== "granted") { micPermission = "granted"; showState(); }
        return stream;
      } catch (err) {
        if (err && err.name === "NotAllowedError") { micPermission = "denied"; showState(); }
        throw err;
      }
    }

    async function startMic() {
      setAudioSession("play-and-record");
      micStream = await getMic({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
      if (!sending) { stopMic(); return; }
      const c = micCtx = new (window.AudioContext || window.webkitAudioContext)();
      await c.audioWorklet.addModule(workletURL);
      if (!sending || micCtx !== c) { stopMic(); return; }
      micSource = c.createMediaStreamSource(micStream);
      micNode = new AudioWorkletNode(c, "tap");
      const ratio = c.sampleRate / RATE;
      let carry = new Float32Array(0);
      micNode.port.onmessage = e => {
        const input = new Float32Array(carry.length + e.data.length);
        input.set(carry); input.set(e.data, carry.length);
        const n = Math.floor(input.length / ratio), out = new Int16Array(n);
        let sum = 0;
        for (let i = 0; i < n; i++) {
          const v = Math.max(-1, Math.min(1, input[Math.floor(i * ratio)]));
          out[i] = v * 32767; sum += v * v;
        }
        carry = input.slice(Math.floor(n * ratio));
        if (sending && ws && ws.readyState === 1) ws.send(out.buffer);
      };
      micSource.connect(micNode);
      // Live spectrum for the voice halo.
      analyser = c.createAnalyser();
      analyser.fftSize = 1024;
      analyser.smoothingTimeConstant = 0.55;
      micSource.connect(analyser);
    }
    // The mic is closed after every press (see Audio routing above).
    function stopMic() {
      try { micSource && micSource.disconnect(); micNode && micNode.disconnect(); } catch (e) {}
      if (micStream) micStream.getTracks().forEach(t => t.stop());
      if (micCtx) { micCtx.close().catch(() => {}); micCtx = null; }
      micStream = micNode = micSource = null;
      setAudioSession("playback");
      analyser = null;
    }

    // ---- Voice halo ----
    // A soft, living outline around the button, drawn on a canvas every
    // screen frame from the microphone's live spectrum (an AnalyserNode on
    // the mic). Around the circle sit 64 points; each follows the loudness of
    // a slice of the speech range (about 90 Hz to 4 kHz, mirrored so the
    // shape stays balanced), so the halo bulges where your voice has energy
    // and changes shape with pitch, not just volume. Each point rises fast
    // and falls slowly, a second, slower layer trails behind for depth, and a
    // gentle drift keeps it alive in silence. Nothing is drawn while the
    // button is up.
    let analyser = null;
    const halo = $("halo"), hctx = halo.getContext("2d");
    const POINTS = 64, freq = new Uint8Array(512), wave = new Float32Array(1024);
    const fast = new Float32Array(POINTS), slow = new Float32Array(POINTS);
    let haloOn = 0, loud = 0;
    function sizeHalo() {
      const d = Math.min(3, window.devicePixelRatio || 1);
      halo.width = 240 * d; halo.height = 240 * d;
      hctx.setTransform(d, 0, 0, d, 0, 0);
    }
    sizeHalo();
    function drawLayer(radii, color, glow) {
      // A smooth closed curve through the points (Catmull-Rom as Béziers).
      const pts = radii.map((r, i) => {
        const a = (i / POINTS) * Math.PI * 2 - Math.PI / 2;
        return [120 + Math.cos(a) * r, 120 + Math.sin(a) * r];
      });
      hctx.beginPath();
      hctx.moveTo(pts[0][0], pts[0][1]);
      for (let i = 0; i < POINTS; i++) {
        const p0 = pts[(i - 1 + POINTS) % POINTS], p1 = pts[i], p2 = pts[(i + 1) % POINTS], p3 = pts[(i + 2) % POINTS];
        hctx.bezierCurveTo(p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6,
                           p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6, p2[0], p2[1]);
      }
      hctx.closePath();
      hctx.shadowColor = glow; hctx.shadowBlur = 18;
      hctx.fillStyle = color; hctx.fill();
      hctx.shadowBlur = 0;
    }
    function drawHalo(now) {
      haloOn += ((held ? 1 : 0) - haloOn) * (held ? 0.25 : 0.12);
      hctx.clearRect(0, 0, 240, 240);
      if (haloOn > 0.01) {
        let level = 0;
        if (analyser) {
          analyser.getByteFrequencyData(freq);
          analyser.getFloatTimeDomainData(wave);
          let sum = 0;
          for (let i = 0; i < wave.length; i++) sum += wave[i] * wave[i];
          const db = 20 * Math.log10(Math.sqrt(sum / wave.length) + 1e-6);
          level = Math.max(0, Math.min(1, (db + 58) / 46));
        }
        loud += (level - loud) * (level > loud ? 0.4 : 0.1);
        const binHz = (analyser ? analyser.context.sampleRate : 48000) / 1024;
        const lo = Math.max(1, Math.round(90 / binHz)), hi = Math.round(4000 / binHz);
        const half = POINTS / 2;
        for (let i = 0; i < POINTS; i++) {
          // Mirror: point i and point POINTS-i share a band; low pitches at the top.
          const k = i <= half ? i : POINTS - i;
          const bin = lo + Math.floor(Math.pow(k / half, 1.6) * (hi - lo));
          let v = analyser ? freq[bin] / 255 : 0;
          v = Math.max(0, (v - 0.25) / 0.75);
          v = v * (0.45 + 0.55 * loud);
          fast[i] += (v - fast[i]) * (v > fast[i] ? 0.55 : 0.16);
          slow[i] += (fast[i] - slow[i]) * 0.08;
        }
        const t = now / 1000, base = 50;
        const drift = i => 1.6 * Math.sin(t * 1.7 + i * 0.6) + 1.2 * Math.sin(t * 1.1 - i * 0.35);
        // Blend each point with its neighbours so the outline stays fluid
        // rather than spiky.
        const soften = a => { for (let pass = 0; pass < 3; pass++) {
          const b = a.slice();
          for (let i = 0; i < POINTS; i++) a[i] = (b[(i - 1 + POINTS) % POINTS] + 2 * b[i] + b[(i + 1) % POINTS]) / 4;
        } return a; };
        const outer = soften(Array.from(slow, (v, i) => base + 6 + loud * 14 + v * 34 + drift(i) * 1.3));
        const inner = soften(Array.from(fast, (v, i) => base + 3 + loud * 8 + v * 26 + drift(i)));
        hctx.globalAlpha = haloOn;
        drawLayer(outer, "rgba(255,107,107,0.16)", "rgba(255,107,107,0.35)");
        drawLayer(inner, "rgba(255,138,128,0.38)", "rgba(255,107,107,0.55)");
        hctx.globalAlpha = 1;
      }
      requestAnimationFrame(drawHalo);
    }
    requestAnimationFrame(drawHalo);

    // Swipe up to cancel: while holding, sliding the finger up past
    // CANCEL_PX arms a cancel (the button greys out, "Release to cancel");
    // letting go there drops the recording instead of sending it. Sliding
    // back down disarms it.
    const CANCEL_PX = 70;
    let startY = 0, cancelArmed = false;
    function setCancelArmed(on) {
      if (on === cancelArmed) return;
      cancelArmed = on;
      $("talk").classList.toggle("cancel", on);
      $("hint").classList.toggle("cancel", on);
      $("hint").textContent = on ? "Release to cancel" : "Listening — let go to send · swipe up to cancel";
      if (navigator.vibrate) navigator.vibrate(on ? 18 : 8);
    }

    function press(e) {
      e.preventDefault();
      if (held || !ws || ws.readyState !== 1) return;
      held = true; sending = true;
      startY = e.clientY; cancelArmed = false;
      try { $("talk").setPointerCapture(e.pointerId); } catch (err) {}
      audioContext();  // unlocks reply playback; iOS only allows that inside a touch
      $("talk").classList.add("held");
      stopAudio();
      send({ type: "press" });
      $("hint").textContent = "Listening — let go to send · swipe up to cancel";
      if (navigator.vibrate) navigator.vibrate(10);
      startMic().catch(err => { banner("Microphone unavailable: " + err.message); release(e); });
    }
    function move(e) {
      if (!held) return;
      setCancelArmed(startY - e.clientY > CANCEL_PX);
    }
    function release(e) {
      if (e) e.preventDefault();
      if (!held) return;
      held = false;
      const cancel = cancelArmed;
      setCancelArmed(false);
      $("talk").classList.remove("held");
      audioContext();  // letting go is a touch, so iOS allows resuming playback here
      if (cancel) {
        sending = false;
        send({ type: "cancel" });
        stopMic();
        $("hint").textContent = "Cancelled";
        setTimeout(() => { if (!held) showState(); }, 900);
        return;
      }
      // Let the last few milliseconds of audio through before closing the mic.
      setTimeout(() => { sending = false; send({ type: "release" }); stopMic(); audioContext(); }, 120);
    }

    const talk = $("talk");
    talk.addEventListener("pointerdown", press);
    talk.addEventListener("pointermove", move);
    talk.addEventListener("pointerup", release);
    talk.addEventListener("pointercancel", release);
    talk.addEventListener("contextmenu", e => e.preventDefault());
    $("replay").addEventListener("click", () => { audioContext(); send({ type: "replay" }); });
    // Reconnect, like the Mac's button: a fresh session for this phone's
    // conversation (the conversation itself is kept). If the page has lost
    // the Mac, it reconnects to the Mac first.
    $("reconnect").addEventListener("click", () => {
      const b = $("reconnect");
      b.classList.remove("spin"); void b.offsetWidth; b.classList.add("spin");
      setTimeout(() => b.classList.remove("spin"), 650);
      if (held) return;
      if (ws && ws.readyState === 1) send({ type: "reconnect" });
      else { replaced = false; if (!ws) connect(); }
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) { if (held) release(); }
      else if (!ws && !replaced) connect();
    });
    connect();
    </script>
    </body>
    </html>
    """#
}
