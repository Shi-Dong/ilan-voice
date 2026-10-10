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
      "theme_color": "#0E1213",
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
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Ilan">
    <meta name="theme-color" content="#0E1213">
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
      body { display: flex; flex-direction: column; overflow: hidden;
        background: radial-gradient(120% 60% at 50% 0%, #15211F 0%, var(--ink) 60%); }
      header { padding: calc(env(safe-area-inset-top) + 14px) 20px 12px; display: flex; align-items: center; gap: 12px;
        border-bottom: 1px solid var(--hair); }
      header img { width: 34px; height: 34px; border-radius: 9px; }
      header .title { font-weight: 600; font-size: 17px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      header .status { font-size: 12.5px; color: var(--dim); display: flex; align-items: center; gap: 6px; }
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
      /* Voice rings behind the button: scaled and faded once per frame from a
         smoothed voice level, which is cheap to draw and moves with speech. */
      .talkwrap { position: relative; width: 96px; height: 96px; }
      .talkwrap #talk { z-index: 1; }
      .ring { position: absolute; inset: 0; border-radius: 50%; pointer-events: none; opacity: 0;
        will-change: transform, opacity; }
      .ring.inner { background: rgba(255,107,107,.30); }
      .ring.outer { background: rgba(255,107,107,.14); }
      #talk.held svg { color: #2A0B0B; }
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
      <div class="talkwrap"><div class="ring outer" id="ringOuter"></div><div class="ring inner" id="ringInner"></div>
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
        phase = m.phase;
        const cls = m.phase === "Listening" ? "rec" : m.busy ? "busy" : m.phase === "Offline" ? "" : "ok";
        setStatus(m.phase, cls);
        banner(m.error || "");
        $("hint").textContent = held ? "Listening — let go to send"
          : m.phase === "Speaking" ? "Tap to stop · hold to interrupt"
          : m.phase === "Thinking" || m.phase === "Using tools" ? m.phase + "…" : "Hold the button and speak";
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

    function setStatus(text, cls) { $("status").textContent = text; $("dot").className = "dot " + cls; }
    function banner(text) { const b = $("banner"); b.textContent = text; b.style.display = text ? "block" : "none"; }
    $("banner").addEventListener("click", () => { if (replaced && !ws) { replaced = false; connect(); } });

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
    function audioContext() {
      if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
      if (ctx.state === "suspended") ctx.resume();
      return ctx;
    }
    function playPCM(buf) {
      const c = audioContext(), pcm = new Int16Array(buf);
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

    async function startMic() {
      setAudioSession("play-and-record");
      micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
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
        levelSum += sum; levelCount += n;
        if (sending && ws && ws.readyState === 1) ws.send(out.buffer);
      };
      micSource.connect(micNode);
    }
    // The mic is closed after every press (see Audio routing above).
    function stopMic() {
      try { micSource && micSource.disconnect(); micNode && micNode.disconnect(); } catch (e) {}
      if (micStream) micStream.getTracks().forEach(t => t.stop());
      if (micCtx) { micCtx.close().catch(() => {}); micCtx = null; }
      micStream = micNode = micSource = null;
      setAudioSession("playback");
      levelSum = levelCount = 0;
    }

    // ---- Voice rings ----
    // Audio arrives in tiny batches hundreds of times a second; the rings are
    // updated once per screen frame instead, from the loudness of everything
    // heard since the last frame. Loudness is taken in decibels (closer to
    // how loud speech sounds), rises quickly when you speak and falls gently
    // between words, so the rings follow the voice without flickering.
    let levelSum = 0, levelCount = 0, level = 0, target = 0, ringsOn = 0;
    const ringInner = $("ringInner"), ringOuter = $("ringOuter");
    function animateRings(now) {
      if (levelCount > 0) {
        const db = 20 * Math.log10(Math.sqrt(levelSum / levelCount) + 1e-6);
        target = Math.max(0, Math.min(1, (db + 58) / 50));
        levelSum = levelCount = 0;
      } else if (!held) target = 0;
      level += (target - level) * (target > level ? 0.3 : 0.12);
      ringsOn += ((held ? 1 : 0) - ringsOn) * 0.18;
      const breathe = held ? 0.025 * Math.sin(now / 420) : 0;
      ringInner.style.transform = "scale(" + (1.08 + breathe + level * 0.38).toFixed(3) + ")";
      ringInner.style.opacity = (ringsOn * (0.55 + level * 0.45)).toFixed(3);
      ringOuter.style.transform = "scale(" + (1.12 + breathe * 1.6 + level * 0.82).toFixed(3) + ")";
      ringOuter.style.opacity = (ringsOn * level * 0.9).toFixed(3);
      requestAnimationFrame(animateRings);
    }
    requestAnimationFrame(animateRings);

    function press(e) {
      e.preventDefault();
      if (held || !ws || ws.readyState !== 1) return;
      held = true; sending = true;
      audioContext();  // unlocks reply playback; iOS only allows that inside a touch
      $("talk").classList.add("held");
      stopAudio();
      send({ type: "press" });
      $("hint").textContent = "Listening — let go to send";
      if (navigator.vibrate) navigator.vibrate(10);
      startMic().catch(err => { banner("Microphone unavailable: " + err.message); release(e); });
    }
    function release(e) {
      if (e) e.preventDefault();
      if (!held) return;
      held = false;
      $("talk").classList.remove("held");
      // Let the last few milliseconds of audio through before closing the mic.
      setTimeout(() => { sending = false; send({ type: "release" }); stopMic(); }, 120);
    }

    const talk = $("talk");
    talk.addEventListener("pointerdown", press);
    talk.addEventListener("pointerup", release);
    talk.addEventListener("pointercancel", release);
    talk.addEventListener("contextmenu", e => e.preventDefault());
    $("replay").addEventListener("click", () => { audioContext(); send({ type: "replay" }); });
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
