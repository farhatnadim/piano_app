// Injected by the app into every frame of the player page, in its own script world (the page's scripts
// can't see it). In the YouTube player's frame it can route the <video> element's sound through Web Audio
// and hand the app the samples, each block stamped with the video's time — a clean copy of the music
// without the microphone.
//
// The app calls PianoAudioTap.start() / stop() in this frame once the frame has said hello.
(function () {
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) { return; }

  var tap = { context: null, source: null, processor: null, video: null, running: false };
  var seen = { blocks: 0, peak: 0 };

  function post(message) {
    try { window.webkit.messageHandlers.pianoAudio.postMessage(message); } catch (e) {}
  }

  // 16-bit PCM as base64: a compact way to pass samples to the app.
  function encode(left, right) {
    var n = left.length;
    var pcm = new Int16Array(n);
    for (var i = 0; i < n; i++) {
      var s = right ? (left[i] + right[i]) * 0.5 : left[i];
      s = s > 1 ? 1 : (s < -1 ? -1 : s);
      pcm[i] = s < 0 ? s * 32768 : s * 32767;
    }
    var bytes = new Uint8Array(pcm.buffer);
    var text = "";
    for (var j = 0; j < bytes.length; j += 0x8000) {
      text += String.fromCharCode.apply(null, bytes.subarray(j, j + 0x8000));
    }
    return btoa(text);
  }

  function onAudio(event) {
    var input = event.inputBuffer;
    var first = input.getChannelData(0);
    seen.blocks += 1;
    for (var k = 0; k < first.length; k += 16) { var a = Math.abs(first[k]); if (a > seen.peak) { seen.peak = a; } }
    if (!tap.running || !tap.video) { return; }
    var video = tap.video;
    post({
      type: "audio",
      rate: input.sampleRate,
      pcm: encode(input.getChannelData(0), input.numberOfChannels > 1 ? input.getChannelData(1) : null),
      // The video's position when this block (its last sample) was heard.
      videoTime: video.currentTime,
      playing: !video.paused && !video.ended && video.readyState > 2,
      playbackRate: video.playbackRate
    });
  }

  function attach(video) {
    var AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) { throw new Error("no Web Audio"); }
    if (!tap.context) { tap.context = new AudioContextClass(); }
    // An element can feed only one source node, ever: keep it for the life of the frame.
    tap.source = tap.context.createMediaElementSource(video);
    tap.source.connect(tap.context.destination);   // still heard as before
    tap.processor = tap.context.createScriptProcessor(4096, 2, 1);
    tap.processor.onaudioprocess = onAudio;
    tap.source.connect(tap.processor);
    tap.processor.connect(tap.context.destination); // writes silence; only pulls the samples
    tap.video = video;
  }

  window.PianoAudioTap = {
    // Returns "ok <state> <rate>", or why it couldn't start.
    start: function () {
      var video = document.querySelector("video");
      if (!video) { return "no video"; }
      try {
        if (tap.video !== video) { attach(video); }
        tap.running = true;
        if (tap.context.state !== "running") { tap.context.resume(); }
        return "ok " + tap.context.state + " " + tap.context.sampleRate;
      } catch (e) {
        return "failed " + e;
      }
    },
    stop: function () {
      tap.running = false;
      return "stopped";
    },
    // What the tap sees, for checking it (JSON).
    stats: function () {
      var v = tap.video || document.querySelector("video");
      return JSON.stringify({
        state: tap.context ? tap.context.state : "none", blocks: seen.blocks, peak: seen.peak,
        src: v ? String(v.currentSrc).slice(0, 40) : "", paused: v ? v.paused : null,
        muted: v ? v.muted : null, volume: v ? v.volume : null, time: v ? v.currentTime : null
      });
    }
  };

  post({ type: "hello" });
})();
