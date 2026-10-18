// The iPhone web app, served by PhoneServer. One page, no build step.
//
// Talking: tap the round button to start a conversation (24 kHz PCM16 is
// streamed to the Mac until you tap again); OpenAI hears when you finish
// each turn. Replies stream back as PCM16 and play straight away. The Mac does everything else: transcription, the model,
// tools, saving the conversation.
enum PhoneWebApp {
    static let manifest = """
    {
      "name": "Ilan Voice",
      "short_name": "Ilan",
      "display": "standalone",
      "background_color": "#131010",
      "theme_color": "#1D1818",
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
    <!-- No viewport-fit=cover: asking to extend under the status bar made iOS
         draw the home-screen page from the very top while still sizing it a
         status bar shorter (an iPhone reported 812 of 874 pt), leaving a black
         band at the bottom that is outside the page. -->
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <!-- An opaque status bar: the page starts below the clock and battery and
         nothing scrolls under them. -->
    <meta name="apple-mobile-web-app-status-bar-style" content="black">
    <meta name="apple-mobile-web-app-title" content="Ilan">
    <meta name="theme-color" content="#1D1818">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon-180.png">
    <title>Ilan Voice</title>
    <style>
      :root {
        --ink: #131010; --raised: #1D1818; --card: rgba(255,255,255,.055); --hair: rgba(255,255,255,.08);
        --text: #F0EAEA; --dim: rgba(255,255,255,.55); --accent: #F4A7A3; --accent-deep: #E0706A; --ready: #A9DCCB; --orange: #F28C2A; --red: #FF6B6B;
      }
      * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
      html, body { margin: 0; height: 100%; background: var(--ink); color: var(--text);
        font: 16px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
      /* The page runs full-screen under the iPhone's status bar (clock,
         battery). The body is pinned to all four edges of the screen rather
         than given a height: as a home-screen app, iOS sometimes reports
         100dvh a little short, and the strip below the body then showed as a
         black band at the bottom. The header is solid and starts at the very
         top, so the status bar sits on a crisp, even band rather than on the
         soft background gradient. */
      body { display: flex; flex-direction: column; overflow: hidden; position: fixed; inset: 0;
        background: radial-gradient(120% 60% at 50% 30%, #231918 0%, var(--ink) 60%); }
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
      #reconnect.spin svg { transform: rotate(180deg); }
      .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--dim); flex: none; }
      .dot.ok { background: var(--ready); } .dot.busy { background: var(--orange); } .dot.rec { background: var(--red); }
      main { flex: 1; overflow-y: auto; padding: 16px 16px 24px; display: flex; flex-direction: column; gap: 10px;
        -webkit-overflow-scrolling: touch; }
      .empty { margin: auto; text-align: center; color: var(--dim); font-size: 15px; padding: 0 30px; }
      .empty b { display: block; color: var(--text); font-size: 20px; margin-bottom: 6px; }
      .msg { max-width: 84%; padding: 9px 13px; border-radius: 17px; font-size: 15.5px; white-space: pre-wrap; word-wrap: break-word; }
      .msg.user { align-self: flex-end; background: var(--accent); color: #1A0E0D; border-bottom-right-radius: 5px; }
      .msg.assistant { align-self: flex-start; background: var(--card); border: 1px solid var(--hair); border-bottom-left-radius: 5px; }
      .msg.tool { align-self: flex-start; font-size: 12.5px; color: var(--dim); padding: 2px 6px; }
      .msg.pending { opacity: .6; }
      footer { padding: 8px 24px max(10px, calc(env(safe-area-inset-bottom) - 8px)); display: grid;
        grid-template-columns: 1fr auto 1fr; align-items: center; border-top: 1px solid var(--hair); background: rgba(19,16,16,.85); }
      .hint { grid-column: 1 / -1; text-align: center; font-size: 12.5px; color: var(--dim); margin-bottom: 6px; min-height: 17px; }
      .side { width: 52px; height: 52px; border-radius: 50%; border: 1px solid var(--hair); background: var(--card); color: var(--text);
        display: flex; align-items: center; justify-content: center; justify-self: start; }
      .side:disabled { opacity: .35; }
      .side svg { width: 22px; height: 22px; }
      #talk { width: 96px; height: 96px; border-radius: 50%; border: none; position: relative; touch-action: none;
        -webkit-user-select: none; user-select: none; -webkit-touch-callout: none;
        background: radial-gradient(circle at 35% 30%, #FFE1DF, var(--accent) 45%, var(--accent-deep));
        box-shadow: 0 0 0 6px rgba(244,167,163,.12), 0 10px 30px rgba(224,112,106,.35); transition: transform .12s; }
      #talk svg { width: 38px; height: 38px; color: #2A1210; }
      #talk.held { transform: scale(1.08); background: radial-gradient(circle at 35% 30%, #FFC9C9, var(--red) 55%, #C94444);
        box-shadow: 0 10px 30px rgba(255,107,107,.35); }
      /* The voice halo: a canvas behind the button, drawn every frame from the
         microphone's live spectrum (see "Voice halo" in the script). */
      .talkwrap { position: relative; width: 96px; height: 96px; }
      .talkwrap #talk { z-index: 1; }
      /* Pocket mode: during a conversation everything else is locked, and the
         talk button only ends it with a hold-and-slide-up. */
      body.conversing #reconnect, body.conversing .banner, body.conversing .sheet { pointer-events: none; opacity: .35; }
      #talk.sliding { transition: none; }
      /* Microphone not allowed yet: a crossed-out mic (a tap asks for it). */
      #talk .icon-nomic, #talk.nomic .icon-mic { display: none; }
      #talk.nomic .icon-nomic { display: inline; }  /* inline like the mic icon, so the button centres it */
      /* The way out of a conversation: shown while a finger is on the button,
         a track rising above it to a stop target. */
      .endtrack { position: absolute; left: 50%; bottom: 0; width: 104px; margin-left: -52px; height: 104px;
        border-radius: 52px; opacity: 0; pointer-events: none; z-index: 0;
        background: linear-gradient(0deg, rgba(255,255,255,.05), rgba(255,107,107,.16));
        border: 1.5px dashed rgba(255,255,255,.35); box-shadow: 0 8px 28px rgba(0,0,0,.35);
        -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);
        transition: opacity .15s, height .2s cubic-bezier(.2,.8,.2,1); }
      .endtrack.show { opacity: 1; height: calc(var(--end-px, 160px) + 104px); }
      .endtrack .chev { position: absolute; left: 0; right: 0; text-align: center; color: rgba(255,255,255,.45);
        font-size: 14px; line-height: 1; }
      .endtrack .target { position: absolute; top: 18px; left: 50%; width: 68px; height: 68px; margin-left: -34px;
        border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-direction: column;
        background: rgba(255,107,107,.18); border: 1px solid rgba(255,107,107,.5); color: #FFD9D6;
        font-size: 10px; font-weight: 600; letter-spacing: .02em; transition: background .12s, transform .12s; }
      .endtrack .target i { width: 14px; height: 14px; border-radius: 3px; background: currentColor; margin-bottom: 3px; }
      .endtrack.ready .target { background: rgba(255,107,107,.75); color: #fff; transform: scale(1.1); }
      #halo { position: absolute; left: 50%; top: 50%; width: 240px; height: 240px; margin: -120px 0 0 -120px;
        pointer-events: none; z-index: 0; }
      #talk.held svg { color: #2A0B0B; }
      /* The Mac is out of reach mid-conversation (see "Connection" in the script). */
      body.away #talk.held { filter: saturate(.3) brightness(.8); }
      body.away #halo { opacity: .35; }
      /* Swiped up far enough: letting go now cancels. */
      #talk.held.cancel { transform: scale(0.92); background: radial-gradient(circle at 35% 30%, #d9dedd, #8b9593 60%, #5f6866);
        box-shadow: 0 10px 30px rgba(0,0,0,.35); }
      #talk.held.cancel svg { color: #1c2221; }
      .hint.cancel { color: var(--red); font-weight: 600; }
      #talk:disabled { filter: grayscale(1) brightness(.6); }
      .sheet { position: fixed; inset: 0; background: rgba(8,5,5,.72); display: none; align-items: flex-end; z-index: 5;
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
      .choice.new { border-style: dashed; color: var(--accent); justify-content: center; font-weight: 600; }
      .banner { margin: 10px 16px 0; padding: 9px 12px; border-radius: 10px; font-size: 13.5px;
        background: rgba(242,140,42,.14); color: var(--orange); display: none; }
    
      /* ---- Liquid Glass ----
         Bars, buttons, bubbles and sheets are translucent glass floating over
         a softly lit background: a real backdrop blur with extra saturation,
         a faint white tint, a bright rim on the top edge and a darker one at
         the bottom (light from above), and a soft drop shadow. The header and
         footer float as rounded panels and the conversation scrolls beneath
         them, so the glass always has something to refract. */
      :root {
        --glass: rgba(255,255,255,.075); --glass-strong: rgba(255,255,255,.11);
        --rim: rgba(255,255,255,.22); --rim-soft: rgba(255,255,255,.10);
        --glass-blur: blur(22px) saturate(185%);
        --glass-shadow: inset 0 1px 0 rgba(255,255,255,.28), inset 0 -1px 0 rgba(0,0,0,.25),
                        0 10px 30px rgba(0,0,0,.35);
      }
      /* Painted on html too, so any edge iOS reveals beyond the body matches. */
      html, body { background:
          radial-gradient(60% 40% at 15% 18%, rgba(244,167,163,.30), transparent 70%),
          radial-gradient(55% 38% at 90% 45%, rgba(169,220,203,.20), transparent 70%),
          radial-gradient(70% 45% at 40% 95%, rgba(224,112,106,.28), transparent 70%),
          var(--ink); }
      header { position: fixed; z-index: 3; left: 10px; right: 10px; top: calc(env(safe-area-inset-top) + 8px);
        padding: 10px 12px 10px 10px; border-radius: 24px; border-bottom: 1px solid var(--rim-soft);
        background: linear-gradient(180deg, var(--glass-strong), var(--glass));
        -webkit-backdrop-filter: var(--glass-blur); backdrop-filter: var(--glass-blur);
        border: 1px solid var(--rim-soft); box-shadow: var(--glass-shadow); }
      header img { border-radius: 10px; box-shadow: 0 2px 8px rgba(0,0,0,.3); }
      #reconnect { background: linear-gradient(180deg, rgba(255,255,255,.16), rgba(255,255,255,.06));
        border: 1px solid var(--rim); color: var(--text); box-shadow: inset 0 1px 0 rgba(255,255,255,.3); }
      main { padding: calc(var(--head-h, 72px) + env(safe-area-inset-top) + 18px) 14px calc(var(--foot-h, 150px) + 16px);
        /* Messages fade out at the very top instead of being sliced off by
           the edge under iOS's black status bar. */
        -webkit-mask-image: linear-gradient(to bottom, transparent 0, #000 56px);
        mask-image: linear-gradient(to bottom, transparent 0, #000 56px); }
      /* The page starts right under iOS's opaque black status bar; this soft
         black-to-clear band melts the bar into the page instead of a hard line. */
      body::after { content: ""; position: fixed; z-index: 2; top: 0; left: 0; right: 0; height: 32px;
        background: linear-gradient(to bottom, #000, rgba(0,0,0,0)); pointer-events: none; }
      .banner { position: fixed; z-index: 3; left: 16px; right: 16px; top: calc(env(safe-area-inset-top) + var(--head-h, 72px) + 16px);
        margin: 0; border-radius: 14px; background: rgba(242,140,42,.16); border: 1px solid rgba(242,140,42,.35);
        -webkit-backdrop-filter: var(--glass-blur); backdrop-filter: var(--glass-blur); }
      .msg { border-radius: 20px; }
      .msg.assistant { background: linear-gradient(180deg, var(--glass-strong), var(--glass));
        -webkit-backdrop-filter: var(--glass-blur); backdrop-filter: var(--glass-blur);
        border: 1px solid var(--rim-soft); box-shadow: inset 0 1px 0 rgba(255,255,255,.18), 0 4px 14px rgba(0,0,0,.18);
        border-bottom-left-radius: 6px; }
      /* Your messages: the same flat coral glass as the talk button. */
      .msg.user { color: #FFF1F0; background: rgba(244,167,163,.36);
        -webkit-backdrop-filter: blur(20px) saturate(190%); backdrop-filter: blur(20px) saturate(190%);
        border: 1px solid rgba(255,255,255,.26); box-shadow: inset 0 1px 0 rgba(255,255,255,.40), 0 4px 14px rgba(0,0,0,.18);
        border-bottom-right-radius: 6px; }
      .msg.tool { background: var(--glass); border: 1px solid var(--rim-soft); border-radius: 999px; padding: 3px 10px; }
      footer { position: fixed; z-index: 3; left: 10px; right: 10px;
        bottom: max(22px, calc(env(safe-area-inset-bottom) - 10px));
        padding: 8px 18px 14px; border-radius: 30px; border-top: 1px solid var(--rim-soft);
        background: linear-gradient(180deg, var(--glass-strong), var(--glass));
        -webkit-backdrop-filter: var(--glass-blur); backdrop-filter: var(--glass-blur);
        border: 1px solid var(--rim-soft); box-shadow: var(--glass-shadow); }
      /* If iOS still hands the page less than the screen (see measureViewport),
         it reports no safe areas either, yet the page still ends at the
         screen's rounded bottom corners: 22px keeps the panel's corners clear
         of them (8px clipped them on an iPhone 17 Pro Max). */
      html.short-page footer { bottom: 22px; }
      /* The talk button: a flat pane of coral glass. An even, see-through
         tint over a uniform backdrop blur, a thin crisp edge and one fine
         highlight along the top edge; no curved shine. Ready (microphone
         allowed, connected, no conversation on): green. Held: the pane turns
         red; swipe-to-cancel armed: grey. */
      #talk { color: #FFE3E1;
        background: rgba(244,167,163,.24);
        -webkit-backdrop-filter: blur(20px) saturate(190%); backdrop-filter: blur(20px) saturate(190%);
        border: 1px solid rgba(255,255,255,.30);
        box-shadow: inset 0 1px 0 rgba(255,255,255,.45), 0 12px 28px rgba(0,0,0,.35); }
      #talk svg { color: #FFE3E1; }
      #talk.ready { color: #E2FBEE; background: rgba(61,214,140,.30);
        box-shadow: inset 0 1px 0 rgba(255,255,255,.45), 0 12px 28px rgba(0,0,0,.35), 0 0 22px rgba(61,214,140,.22); }
      #talk.ready svg { color: #E2FBEE; }
      #talk.held { color: #fff; background: rgba(255,107,107,.48);
        border-color: rgba(255,255,255,.40);
        box-shadow: inset 0 1px 0 rgba(255,255,255,.55), 0 12px 30px rgba(0,0,0,.35), 0 0 26px rgba(255,107,107,.35); }
      #talk.held svg { color: #fff; }
      #talk.held.cancel { background: rgba(150,160,158,.40); box-shadow: inset 0 1px 0 rgba(255,255,255,.45), 0 12px 28px rgba(0,0,0,.35); }
      #talk.held.cancel svg { color: #EEF2F1; }
      .sheet { background: rgba(8,5,5,.45); -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px); }
      .sheet .panel { margin: 0 8px 8px; border-radius: 30px;
        background: linear-gradient(180deg, rgba(255,255,255,.14), rgba(255,255,255,.07));
        -webkit-backdrop-filter: var(--glass-blur); backdrop-filter: var(--glass-blur);
        border: 1px solid var(--rim); box-shadow: var(--glass-shadow); }
      .choice { border-radius: 18px; background: linear-gradient(180deg, rgba(255,255,255,.10), rgba(255,255,255,.04));
        border: 1px solid var(--rim-soft); box-shadow: inset 0 1px 0 rgba(255,255,255,.18); }
          /* Costs and token counts (shown when the Mac's setting is on). */
      #cost { font-variant-numeric: tabular-nums; }
      .usage { align-self: flex-start; margin: -6px 0 2px 8px; font-size: 11.5px; color: var(--dim);
        font-variant-numeric: tabular-nums; }
    </style>
    </head>
    <body>
    <header>
      <img src="/icon-180.png" alt="">
      <div style="min-width:0">
        <div class="title" id="title">Ilan Voice</div>
        <div class="status"><span class="dot" id="dot"></span><span id="status">Connecting…</span><span id="cost"></span></div>
      </div>
      <button id="reconnect" aria-label="Reconnect">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M4.5 10a8 8 0 0 1 14.2-3.5"/><path d="M19.5 3v4h-4"/>
          <path d="M19.5 14a8 8 0 0 1-14.2 3.5"/><path d="M4.5 21v-4h4"/></svg>
      </button>
    </header>
    <div class="banner" id="banner"></div>
    <div class="sheet" id="sheet"><div class="panel">
      <h2>Which iPhone is this?</h2>
      <p>Pick it to carry on with its conversation, for example after adding Ilan to the home screen again.</p>
      <div id="phones"></div>
      <button class="choice new" id="newPhone">This is a new iPhone</button>
    </div></div>
    <main id="list"><div class="empty"><b>Tap to start a conversation</b>Then just talk. Ilan answers out loud.</div></main>
    <footer>
      <div class="hint" id="hint">Tap to start a conversation</div>
      <span></span>
      <div class="talkwrap"><canvas id="halo"></canvas>
      <div class="endtrack" id="endtrack" aria-hidden="true"><div class="target"><i></i>End</div>
        <div class="chev" style="top: 108px">︿</div><div class="chev" style="top: 128px">︿</div><div class="chev" style="top: 148px">︿</div></div>
      <button id="talk" aria-label="Start or end a conversation">
        <svg class="icon-mic" viewBox="0 0 24 24" fill="currentColor"><path d="M12 15a3.5 3.5 0 0 0 3.5-3.5v-6a3.5 3.5 0 1 0-7 0v6A3.5 3.5 0 0 0 12 15Z"/>
          <path d="M18.5 11.5a.9.9 0 1 0-1.8 0 4.7 4.7 0 0 1-9.4 0 .9.9 0 1 0-1.8 0 6.5 6.5 0 0 0 5.6 6.4V20H8.8a.9.9 0 1 0 0 1.8h6.4a.9.9 0 1 0 0-1.8H12.9v-2.1a6.5 6.5 0 0 0 5.6-6.4Z"/></svg>
      <svg class="icon-nomic" viewBox="0 0 24 24"><defs><mask id="nomic-cut"><rect width="24" height="24" fill="#fff"/>
          <path d="M4.5 3.5 20.5 19.5" stroke="#000" stroke-width="4.6" stroke-linecap="round"/></mask></defs>
          <g fill="currentColor" mask="url(#nomic-cut)"><path d="M12 15a3.5 3.5 0 0 0 3.5-3.5v-6a3.5 3.5 0 1 0-7 0v6A3.5 3.5 0 0 0 12 15Z"/>
          <path d="M18.5 11.5a.9.9 0 1 0-1.8 0 4.7 4.7 0 0 1-9.4 0 .9.9 0 1 0-1.8 0 6.5 6.5 0 0 0 5.6 6.4V20H8.8a.9.9 0 1 0 0 1.8h6.4a.9.9 0 1 0 0-1.8H12.9v-2.1a6.5 6.5 0 0 0 5.6-6.4Z"/></g>
          <path d="M4.5 3.5 20.5 19.5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" fill="none"/></svg>
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
    let replaced = false, paired = true;

    let ws = null, ctx = null, playHead = 0, sources = [];
    let micStream = null, micNode = null, micSource = null, held = false, sending = false, phase = "Offline";
    let starting = false;  // a conversation's start sound is playing; the Mac hears of it afterwards

    // ---- Connection ----
    // The connection to the Mac comes and goes with the phone's network (a
    // tunnel, a Wi-Fi hand-off). A conversation survives that: the page keeps
    // the microphone and the screen, shows "Reconnecting…", and carries on
    // once the Mac is back. The Mac keeps the conversation for a while on its
    // side too (a little less than AWAY_LIMIT_MS: the Mac decides first) and
    // says in hello_ok whether it still has it. What was said while the
    // connection was down is lost, and a reply that was playing is cut.
    // A dead connection shows as silence, not a close (iOS and Tailscale can
    // take minutes to notice): the Mac pings every 2 s, and a connection with
    // nothing heard for SILENCE_MS is given up on. Retries come quickly at
    // first, then every 2 s, and at once when iOS says the network is back.
    const RETRY_MS = [250, 500, 1000, 2000], CONNECT_TIMEOUT_MS = 5000, SILENCE_MS = 6000, AWAY_LIMIT_MS = 150000;
    let online = false, everOnline = false, attempt = 0, lastHeard = 0, retry = null, awaySince = 0;
    function connect() {
      if (ws) return;
      clearTimeout(retry); retry = null;
      if (!token) { banner("Open the link shown in Ilan Voice on your Mac (Settings → General → iPhone)."); return; }
      const socket = ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws");
      socket.binaryType = "arraybuffer";
      socket.onopen = () => { lastHeard = Date.now(); socket.send(JSON.stringify({ type: "hello", token, device, conversing: held && !starting })); };
      socket.onmessage = e => { lastHeard = Date.now(); if (typeof e.data === "string") onJSON(JSON.parse(e.data)); else playPCM(e.data); };
      socket.onclose = () => dropped(socket);
      // iOS can take ages to give up on a connection that isn't going anywhere.
      setTimeout(() => { if (socket === ws && socket.readyState !== 1) abandon(socket); }, CONNECT_TIMEOUT_MS);
    }
    // Gives up on a connection (dead, or never opening): nothing more is heard
    // from it, not even a late "replaced", and a new one is tried.
    function abandon(socket) {
      socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
      try { socket.close(); } catch (e) {}
      dropped(socket);
    }
    function dropped(socket) {
      if (socket !== ws) return;  // a connection already given up on, closing late
      ws = null; online = false;
      if (replaced || !paired) {  // another window took over, or the link is no longer paired: no retrying
        if (held) stopConversation(true);
        showState();
        return;
      }
      if (held && !awaySince) awaySince = Date.now();
      showState();  // "Reconnecting…"; a conversation waits
      retry = setTimeout(connect, RETRY_MS[Math.min(attempt++, RETRY_MS.length - 1)]);
    }
    // Once a second: a conversation whose Mac has been out of reach for too
    // long is let go (the Mac has let it go by now), and a connection gone
    // silent is given up on.
    function checkConnection() {
      if (held && awaySince && Date.now() - awaySince > AWAY_LIMIT_MS) {
        stopConversation(true);
        banner("Connection lost — the conversation ended. Tap the button to start again.");
      }
      if (ws && ws.readyState === 1 && Date.now() - lastHeard > SILENCE_MS) abandon(ws);
    }
    setInterval(checkConnection, 1000);
    // The network or the page is back: don't wait for the next retry.
    function retryNow() {
      if (replaced || !paired) return;
      attempt = 0;
      if (ws && ws.readyState === 1 && Date.now() - lastHeard <= SILENCE_MS) return;  // still fine
      if (ws) abandon(ws); else connect();
    }
    window.addEventListener("online", retryNow);
    function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }

    function onJSON(m) {
      if (m.type === "hello_ok") {
        online = everOnline = true; attempt = 0; awaySince = 0; replaced = false;
        banner(""); measureViewport(true);
        // Back mid-conversation: the Mac kept the conversation (carry on), or
        // let it go meanwhile (too long away, or Ilan ended it): then end here too.
        if (held && !starting && !m.conversing) stopConversation(true);
        showState();
      }
      else if (m.type === "ping") { send({ type: "pong" }); }
      else if (m.type === "choose_phone") { choosePhone(m.phones); }
      else if (m.type === "replaced") { replaced = true;  // the Mac closes this connection next (see dropped)
        banner("Ilan was opened in another window on this phone. Tap here to use it in this one."); }
      else if (m.type === "auth_failed") { paired = false; localStorage.removeItem("ilanToken");
        banner("This link is no longer paired. Open the current link from Ilan Voice on your Mac."); }
      else if (m.type === "state") {
        lastState = m;
        showState();
      }
      else if (m.type === "messages") { render(m); }
      else if (m.type === "audio_stop") { stopAudio(); }
      else if (m.type === "conversation_ended") { stopConversation(true); }
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
      // Without the microphone the button shows a crossed-out mic: a tap only asks for it.
      $("talk").classList.toggle("nomic", micPermission !== "granted" && !held);
      // Green when a tap would start a conversation right away: the microphone
      // is allowed, the Mac is connected, and no conversation is on.
      $("talk").classList.toggle("ready", micPermission === "granted" && online && !held);
      // Mid-conversation without the Mac: the mic stays on (dimmed) and the conversation waits.
      document.body.classList.toggle("away", held && !online);
      if (!online) {
        setStatus(replaced ? "Open in another window" : !paired ? "Not paired" : everOnline ? "Reconnecting…" : "Connecting…", "");
        if (held) $("hint").textContent = "Reconnecting… · push the button up to end";
        return;
      }
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
        $("hint").textContent = "Tap the button to allow the microphone";
      } else {
        const cls = m.phase === "Listening" ? "rec" : m.busy ? "busy" : m.phase === "Offline" ? "" : "ok";
        setStatus(m.phase, cls);
        $("hint").textContent = held
          ? (starting ? "Starting…"
             : m.phase === "Speaking" ? "Speak to interrupt · push the button up to end"
             : m.phase === "Thinking" || m.phase === "Using tools" ? m.phase + "… · push the button up to end"
             : "Listening — just talk · push the button up to end")
          : "Tap to start a conversation";
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
      // The conversation's cost so far, when the Mac shows costs.
      $("cost").textContent = m.cost ? "· " + m.cost : "";
      const list = $("list");
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
      list.innerHTML = "";
      if (!m.items.length) {
        list.innerHTML = '<div class="empty"><b>Tap to start a conversation</b>Then just talk. Ilan answers out loud.</div>';
      }
      for (const it of m.items) {
        if (it.role === "user" && !it.text) continue;
        const d = document.createElement("div");
        d.className = "msg " + it.role + (it.pending ? " pending" : "");
        d.textContent = it.role === "tool" ? "⚙︎ " + it.text : (it.text || "…");
        list.appendChild(d);
        if (it.usage) {
          const u = document.createElement("div");
          u.className = "usage"; u.textContent = it.usage;
          list.appendChild(u);
        }
      }
      if (atBottom || m.items.length) list.scrollTop = list.scrollHeight;
    }

    // ---- Audio routing ----
    // iOS sends sound to the quiet earpiece whenever a page's audio session
    // is in "play and record" mode, which is what using the microphone
    // switches it to. Replies play from their own audio context; the
    // microphone gets a separate one that only exists during a conversation.
    // The start and end sounds play with the session set to "playback" (the
    // loudspeaker), so the mic opens only after the start sound and is
    // closed before the end sound. When a conversation ends, both contexts
    // are closed and the session goes back to "auto" (see releaseAudio).
    function setAudioSession(type) {
      try { if (navigator.audioSession) navigator.audioSession.type = type; } catch (e) {}
    }
    // No claim on the phone's audio until a conversation starts: a page that
    // holds a "playback" session or a running audio context shows up in iOS's
    // Now Playing (and the mic/speaker stay taken) even when it is silent.
    setAudioSession("auto");

    // Keep the screen on during a conversation: when the iPhone auto-locks,
    // the page is hidden, iOS cuts its microphone, and the conversation ends.
    // Released when the conversation ends, so Auto-Lock works again.
    // One request at a time: ending and restarting quickly must not leave a
    // second, forgotten lock holding the screen on.
    let wakeLock = null, wakeLockAsked = false;
    async function keepScreenOn() {
      if (!navigator.wakeLock || wakeLock || wakeLockAsked) return;
      wakeLockAsked = true;
      try { wakeLock = await navigator.wakeLock.request("screen"); } catch (e) {}
      wakeLockAsked = false;
      if (!held) letScreenSleep();  // ended while the request was pending
    }
    function letScreenSleep() {
      if (wakeLock) { wakeLock.release().catch(() => {}); wakeLock = null; }
    }

    // After a conversation (and its end sound): let go of the speaker too.
    let ending = false;  // the end sound is still ringing
    function releaseAudio(afterMs) {
      setTimeout(() => {
        ending = false;
        if (held) return;  // a new conversation started meanwhile
        stopAudio();
        if (ctx) { ctx.onstatechange = null; ctx.close().catch(() => {}); ctx = null; }
        soundOut = null;
        setAudioSession("auto");
      }, afterMs);
    }

    // ---- Playback ----
    // Switching the audio session for the microphone and back leaves the
    // playback context "interrupted" on iOS (not just "suspended"), and it
    // stays silent until it is resumed. So: resume whenever it isn't running,
    // after every press, and on every reply; and if iOS still won't let it
    // play, ask for one tap.
    function audioContext() {
      if (!ctx || ctx.state === "closed") {
        ctx = new (window.AudioContext || window.webkitAudioContext)();
        // iOS pauses it when the mic switches routes; resume it, but only
        // during a conversation and its end sound (otherwise a paused context
        // is what we want).
        ctx.onstatechange = () => { if ((held || ending) && ctx && ctx.state !== "running") ctx.resume().catch(() => {}); };
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
      if (!held) return;  // a stray bit of reply after the conversation ended
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
        if (sending && online && ws && ws.readyState === 1) ws.send(out.buffer);
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

    // Conversation mode: tap once to start talking with Ilan hands-free, tap
    // again to end it. While it is on the mic streams continuously; OpenAI
    // decides from what you say when you have finished (semantic turn
    // detection) and answers, and speaking over Ilan stops its reply.
    // Starting goes in order: the start sound plays on the loudspeaker, all
    // of it; only then does the conversation start (the Mac hears of it, and
    // the mic opens, which moves the sound to the earpiece).
    function startConversation() {
      if (held || !online) return;
      held = true; starting = true;
      document.body.classList.add("conversing");
      setAudioSession("playback");  // the start sound plays on the loudspeaker
      audioContext();  // unlocks reply playback; iOS only allows that inside a touch
      $("talk").classList.add("held");
      stopAudio();
      keepScreenOn();
      showState();
      const conversation = ++conversations;
      playSound(true).then(() => {
        if (conversation !== conversations || !held) return;  // ended meanwhile
        starting = false; sending = true;
        send({ type: "conversation_start" });
        showState();
        startMic().catch(err => { banner("Microphone unavailable: " + err.message); stopConversation(); });
      });
    }
    let conversations = 0;
    // byIlan: Ilan ended it (its end_conversation tool, after its goodbye),
    // so the Mac already knows; everything else is the same, closing sound too.
    function stopConversation(byIlan) {
      if (!held) return;
      const started = !starting;  // ended during the start sound: the Mac never heard of it
      held = false; sending = false; starting = false; awaySince = 0;
      document.body.classList.remove("conversing");
      $("talk").classList.remove("held");
      if (endGesture) resetEndGesture();
      stopAudio();  // Ilan goes quiet at once, before the Mac even hears about it
      if (!byIlan && started) send({ type: "conversation_stop" });
      letScreenSleep();
      stopMic();
      ending = true;
      setAudioSession("playback");  // with the mic closed, the end sound plays on the loudspeaker
      audioContext();
      showState();
      playSound(false).then(() => releaseAudio(0));  // once the end sound has rung out
    }
    // ---- Sound feedback for starting and ending a conversation ----
    // "Halo", made on the spot (no files): two soft sine notes a fifth apart
    // that fade in, linger a moment and fade out, about 1.35 s. Start: D and
    // A, rising; end: A and E an octave below, settling low. A short, darkened echo adds
    // space, and a gentle compressor evens it out.
    // iOS cuts off the start of a sound that plays while it is still
    // switching the phone's audio on, or over to another route (the
    // loudspeaker, after the mic): the audio context's clock can already be
    // running while the speaker is still silent. So playSound first plays
    // an inaudible hum until the context has been running steadily for
    // SOUND_SETTLE_MS, so the speaker is really on when the sound starts
    // (tried on an iPhone: the most reliable of several waits). The hum goes
    // on under the sound until it is over, so the speaker never idles in
    // between. After a long quiet spell the phone's audio takes longer to
    // wake up than right after another sound, hence the generous wait.
    // playSound resolves once the sound and its echo are over, timed on the
    // audio clock (which stops while iOS pauses it, so a paused sound is
    // still waited for).
    const SOUND_LEN = 1.35, SOUND_TAIL = 0.35, SOUND_SETTLE_MS = 700, SOUND_WAIT_MAX_MS = 2500, SOUND_POLL_MS = 20;
    const wait = ms => new Promise(r => setTimeout(r, ms));
    async function soundReady(c) {
      let steadySince = null;  // audio-clock time since when the context has been running
      for (let waited = 0; waited < SOUND_WAIT_MAX_MS; waited += SOUND_POLL_MS) {
        if (c.state === "closed") break;
        if (c.state !== "running") { steadySince = null; c.resume().catch(() => {}); }
        else if (steadySince === null) steadySince = c.currentTime;
        else if (c.currentTime - steadySince >= SOUND_SETTLE_MS / 1000) break;
        await wait(SOUND_POLL_MS);
      }
    }
    // A very quiet tone (about -66 dB, far below hearing on a phone).
    function hum(c) {
      const n = Math.round(c.sampleRate / 10), buf = c.createBuffer(1, n, c.sampleRate), ch = buf.getChannelData(0);
      for (let i = 0; i < ch.length; i++) ch[i] = 0.0005 * Math.sin(2 * Math.PI * 220 * i / c.sampleRate);
      const src = c.createBufferSource();
      src.buffer = buf; src.loop = true; src.connect(c.destination); src.start();
      return () => { try { src.stop(); src.disconnect(); } catch (e) {} };
    }
    async function playSound(starting) {
      const c = audioContext();
      const stopHum = hum(c);
      await soundReady(c);
      if (c.state === "closed") { stopHum(); return; }
      const bus = soundBus(c), t = c.currentTime + 0.03, end = t + SOUND_LEN + SOUND_TAIL;
      if (starting) {
        note(c, bus, D5, t, 0.17, 0.09, SOUND_LEN);
        note(c, bus, A5, t + 0.06, 0.136, 0.09, SOUND_LEN);
      } else {
        // Low A and E. A phone's small speaker barely plays notes this low,
        // so each has a soft octave above it, which the speaker does play.
        note(c, bus, A3, t, 0.135, 0.072, SOUND_LEN, 0.5);
        note(c, bus, E4, t, 0.086, 0.072, SOUND_LEN * 0.9, 0.5);
      }
      const limit = (SOUND_LEN + SOUND_TAIL) * 1000 + SOUND_WAIT_MAX_MS;
      for (let waited = 0; c.state !== "closed" && c.currentTime < end && waited < limit; waited += SOUND_POLL_MS) await wait(SOUND_POLL_MS);
      stopHum();
    }
    let soundOut = null;
    function soundBus(c) {
      if (soundOut && soundOut.context === c) return soundOut;
      const comp = c.createDynamicsCompressor();
      comp.threshold.value = -20; comp.knee.value = 14; comp.ratio.value = 3;
      comp.attack.value = 0.004; comp.release.value = 0.2;
      const out = c.createGain(); out.gain.value = 2.5;
      // A limiter last: at this volume the loudest moments would go past full
      // scale and crackle; it turns down just those, everything else stays loud.
      const limit = c.createDynamicsCompressor();
      limit.threshold.value = -3; limit.knee.value = 0; limit.ratio.value = 20;
      limit.attack.value = 0.002; limit.release.value = 0.1;
      comp.connect(out); out.connect(limit); limit.connect(c.destination);
      const echo = c.createDelay(0.5), fb = c.createGain(), dark = c.createBiquadFilter(), wet = c.createGain();
      echo.delayTime.value = 0.09; fb.gain.value = 0.32; dark.type = "lowpass"; dark.frequency.value = 2600; wet.gain.value = 0.2;
      echo.connect(dark); dark.connect(fb); fb.connect(echo); dark.connect(wet); wet.connect(comp);
      soundOut = { context: c, dry: comp, echo };
      return soundOut;
    }
    // octave: how loud a soft octave above the note is (0: none).
    function note(c, bus, freq, at, peak, attack, len, octave = 0) {
      const g = c.createGain();
      g.gain.setValueAtTime(0.0001, at);
      g.gain.exponentialRampToValueAtTime(peak, at + attack);
      g.gain.exponentialRampToValueAtTime(peak * 0.55, at + attack + 0.225);  // lingers a moment
      g.gain.exponentialRampToValueAtTime(0.0001, at + len);
      g.connect(bus.dry); g.connect(bus.echo);
      for (const [mult, level] of [[1, 1], [2, octave]]) {
        if (!level) continue;
        const o = c.createOscillator(), v = c.createGain();
        o.type = "sine"; o.frequency.value = freq * mult; v.gain.value = level;
        o.connect(v); v.connect(g);
        o.start(at); o.stop(at + len + 0.05);
      }
    }
    const A3 = 220, E4 = 329.63, D5 = 587.33, A5 = 880;

    // Starting is a tap. Ending is deliberate, so a phone in a pocket (screen
    // on) can't end it by a stray touch: touching the button shows a track
    // rising to an "End" target; push the button all the way up it
    // (END_SLIDE_PX) and let go. Anything shorter, or drifting well off to the
    // side, springs back.
    const END_SLIDE_PX = 160, END_SIDE_PX = 70;
    document.documentElement.style.setProperty("--end-px", END_SLIDE_PX + "px");
    let endGesture = null;  // { id, x, y } while a finger is on the button mid-conversation
    function resetEndGesture() {
      endGesture = null;
      $("talk").classList.remove("sliding");
      $("talk").style.transform = "";
      $("endtrack").classList.remove("show", "ready");
      if (held) showState();
    }
    function endDown(e) {
      if (!held) return;
      e.preventDefault();
      endGesture = { id: e.pointerId, x: e.clientX, y: e.clientY };
      try { $("talk").setPointerCapture(e.pointerId); } catch (err) {}
      $("endtrack").classList.add("show");
      $("hint").textContent = "Push up to End";
    }
    function endMove(e) {
      if (!held || !endGesture || e.pointerId !== endGesture.id) return;
      if (Math.abs(e.clientX - (endGesture.x || 0)) > END_SIDE_PX) { resetEndGesture(); return; }  // off the track
      const up = Math.max(0, Math.min(END_SLIDE_PX, endGesture.y - e.clientY));
      $("talk").classList.add("sliding");
      $("talk").style.transform = "translateY(" + (-up) + "px)";
      endGesture.ready = up >= END_SLIDE_PX;
      $("endtrack").classList.toggle("ready", endGesture.ready);
      $("hint").textContent = endGesture.ready ? "Let go to end" : "Push up to End";
    }
    function endUp(e) {
      if (!endGesture || e.pointerId !== endGesture.id) return;
      const ready = endGesture.ready;
      resetEndGesture();
      if (ready && held) stopConversation();
    }
    function tap(e) {
      e.preventDefault();
      if (held) return;  // during a conversation a tap does nothing
      // No microphone yet: this tap only asks for it. Starting is a second tap.
      if (micPermission !== "granted") { askForMic(); return; }
      startConversation();
    }
    // Ask iOS for the microphone, then let it go straight away: the point is
    // the permission, not a recording.
    async function askForMic() {
      if (micPermission === "unavailable") return;
      try {
        const stream = await getMic({ audio: true });
        stream.getTracks().forEach(t => t.stop());
      } catch (err) {}
      setAudioSession("auto");
      showState();
    }

    const talk = $("talk");
    talk.addEventListener("click", tap);
    showState();  // the button's icon reflects the microphone permission from the start
    talk.addEventListener("pointerdown", endDown);
    talk.addEventListener("pointermove", endMove);
    talk.addEventListener("pointerup", endUp);
    talk.addEventListener("pointercancel", resetEndGesture);
    talk.addEventListener("contextmenu", e => e.preventDefault());
    // Reconnect, like the Mac's button: a fresh session for this phone's
    // conversation (the conversation itself is kept). If the page has lost
    // the Mac, it reconnects to the Mac first.
    $("reconnect").addEventListener("click", () => {
      const b = $("reconnect");
      b.classList.remove("spin"); void b.offsetWidth; b.classList.add("spin");
      setTimeout(() => b.classList.remove("spin"), 650);
      if (held) return;
      if (online) send({ type: "reconnect" });
      else { replaced = false; retryNow(); }
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) { if (held) stopConversation(); }
      else retryNow();
    });
    // The header and footer float over the conversation (Liquid Glass); keep
    // the list's padding equal to the room they take. For the footer that is
    // its height plus the gap under it (it floats above the bottom edge), so
    // the last message clears its top edge when scrolled to the bottom.
    const sizeBars = () => {
      document.documentElement.style.setProperty("--head-h", document.querySelector("header").offsetHeight + "px");
      const foot = document.querySelector("footer");
      const fromBottom = Math.round(window.innerHeight - foot.getBoundingClientRect().top);
      document.documentElement.style.setProperty("--foot-h", Math.max(foot.offsetHeight, fromBottom) + "px");
    };
    window.addEventListener("resize", sizeBars);
    // Some iOS versions give a home-screen web app a page a little shorter
    // than the screen (by about the status bar's height), leaving a black
    // band at the bottom that is outside the page (iOS doesn't draw the page
    // there, so stretching into it only hides the footer). Report the sizes
    // and the shortfall (upright only: in landscape screen.height is the long
    // side) to the Mac, which logs them (phone-viewport.log in Ilan Voice's
    // data folder) to diagnose such bugs.
    function measureViewport(report) {
      const upright = window.innerHeight > window.innerWidth;
      const screenH = Math.max(screen.width, screen.height);
      const standalone = !!navigator.standalone || matchMedia("(display-mode: standalone)").matches;
      const gap = standalone && upright ? Math.max(0, Math.round(screenH - window.innerHeight)) : 0;
      // Short by more than a status bar's slack: the page ends above the home bar.
      document.documentElement.classList.toggle("short-page", gap > 30);
      if (typeof sizeBars === "function") sizeBars();  // the footer's gap just changed
      if (!report) return;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;visibility:hidden;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)";
      document.body.appendChild(probe);
      const cs = getComputedStyle(probe);
      send({ type: "viewport", innerHeight: window.innerHeight, innerWidth: window.innerWidth,
             screenHeight: screen.height, screenWidth: screen.width,
             visualHeight: window.visualViewport ? Math.round(window.visualViewport.height) : null,
             docHeight: document.documentElement.clientHeight,
             safeTop: parseFloat(cs.paddingTop), safeBottom: parseFloat(cs.paddingBottom),
             standalone, gap, dpr: window.devicePixelRatio });
      probe.remove();
    }
    window.addEventListener("resize", () => measureViewport(true));
    measureViewport(false);
    new ResizeObserver(sizeBars).observe(document.querySelector("header"));
    new ResizeObserver(sizeBars).observe(document.querySelector("footer"));
    sizeBars();
    connect();
    </script>
    </body>
    </html>
    """#
}
