import SwiftUI
import WebKit
import SharedLogging

/// A point-in-time snapshot of everything the Status tab presents. Built on the
/// MainActor from `SDRController` + `LiveAudioServerClient` and pushed into the
/// web view as JSON.
struct StatusSnapshot: Codable, Equatable {
    var serverRunning: Bool = false
    var listenerCount: Int = 0

    /// Human-readable tuning summary (e.g. "Tuned to KUAR").
    var statusFunction: String = ""
    var stationName: String = ""
    var frequencyDisplay: String = ""
    var modulation: String = ""
    var samplingMode: String = ""

    /// 0.0 – 1.0. Not yet driven by live RTL-SDR data, so currently always 0.
    var signalLevel: Double = 0.0
    var squelchLevel: String = ""
    var tunerGain: String = ""
    var tunerAGC: Bool = false
    var sampleRate: String = ""
    var audioOutputFilter: String = ""
    var options: String = ""

    /// Local time the pipeline was last started/stopped, pre-formatted for display ("—" if never).
    var pipelineLastStarted: String = ""
    var pipelineLastStopped: String = ""

    var devices: [RTLSDRDevice] = []
    var stages: [Stage] = []

    /// Plain-text task dump — same format as ControlBooth's pipeline text view
    /// (`TaskPipelineManager.tasksInfoString()`), shown under the SVG diagram.
    var pipelineText: String = ""

    /// The live pipeline's stages as `|`-joined CLI text (via `CLIStageText`,
    /// from the PipelineHelpers package shared with ControlBooth) — what the
    /// "Copy Pipeline" button copies. Pastes directly into a ControlBooth
    /// pipeline's stage list.
    var pipelineCLIText: String = ""

    struct Stage: Codable, Equatable {
        var name: String
        /// Secondary line, e.g. "PID 1234".
        var detail: String
        /// Full path to the executable, shown in the hover panel.
        var path: String
        /// Individual launch arguments, shown in the hover panel.
        var args: [String]
        var running: Bool
        /// Label for the connector feeding this node ("" for the first stage,
        /// "pipe" for stdout→stdin chaining, "UDP" for the LiveAudioServer hop).
        var link: String
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Renders the Status tab entirely in a `WKWebView`: data items as HTML, the
/// task pipeline as an inline SVG flow diagram. A static HTML shell is loaded
/// once; subsequent state changes are pushed via `applyStatus(...)` so the page
/// is never reloaded (no flicker, stable SVG).
struct StatusWebView: NSViewRepresentable {
    var snapshot: StatusSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator
        webView.loadHTMLString(Self.htmlShell, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.apply(snapshot.json, to: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var isLoaded = false
        private var latestJSON: String?

        func apply(_ json: String, to webView: WKWebView) {
            latestJSON = json
            guard isLoaded else { return }
            evaluate(json, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let json = latestJSON {
                evaluate(json, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                LogStore.shared.log(.error, source: "StatusWebView", "navigation failed: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                LogStore.shared.log(.error, source: "StatusWebView", "provisional navigation failed: \(error)")
            }
        }

        private func evaluate(_ json: String, in webView: WKWebView) {
            webView.evaluateJavaScript("applyStatus(\(json));") { _, error in
                if let error {
                    MainActor.assumeIsolated {
                        LogStore.shared.log(.error, source: "StatusWebView", "JS error: \(error)")
                    }
                }
            }
        }
    }
}

private extension StatusWebView {
    static let htmlShell = #"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {
    --bg: #f2f2f7;
    --card: #ffffff;
    --card-border: rgba(0,0,0,0.08);
    --text: #1c1c1e;
    --muted: #6e6e73;
    --accent: #0a84ff;
    --node: #f5f9ff;
    --node-border: #0a84ff;
    --node-stopped-border: #c4c4c6;
    --arrow: #8e8e93;
    --udp: #0a84ff;
    --on: #34c759;
    --off: #ff453a;
    --meter-track: rgba(0,0,0,0.08);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1c1c1e;
      --card: #2c2c2e;
      --card-border: rgba(255,255,255,0.10);
      --text: #f2f2f7;
      --muted: #9e9ea3;
      --accent: #0a84ff;
      --node: #25303f;
      --node-border: #409cff;
      --node-stopped-border: #5a5a5e;
      --arrow: #8e8e93;
      --udp: #409cff;
      --on: #30d158;
      --off: #ff453a;
      --meter-track: rgba(255,255,255,0.12);
    }
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
    font-size: 13px;
    -webkit-font-smoothing: antialiased;
  }
  .wrap {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 14px;
    padding: 16px;
  }
  .card {
    background: var(--card);
    border: 1px solid var(--card-border);
    border-radius: 12px;
    padding: 14px 16px;
  }
  .card.full { grid-column: 1 / -1; }
  h2 {
    margin: 0 0 10px;
    font-size: 11px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--muted);
  }
  .row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 5px 0;
  }
  .row + .row { border-top: 1px solid var(--card-border); }
  .lbl { color: var(--muted); white-space: nowrap; }
  .val {
    text-align: right;
    font-weight: 500;
    overflow-wrap: anywhere;
  }
  .dot {
    display: inline-block;
    width: 8px; height: 8px;
    border-radius: 50%;
    margin-right: 5px;
    background: var(--off);
    vertical-align: middle;
  }
  .dot.on { background: var(--on); }
  .dot.off { background: var(--off); }
  .meter {
    flex: 1;
    min-width: 90px;
    max-width: 200px;
    height: 10px;
    border-radius: 5px;
    background: var(--meter-track);
    overflow: hidden;
  }
  .meter > span {
    display: block;
    height: 100%;
    width: 0%;
    border-radius: 5px;
    background: linear-gradient(90deg, var(--on), #ffd60a 75%, var(--off));
    transition: width 0.2s linear;
  }
  #pipeline { overflow-x: auto; padding-top: 2px; }
  .idle { color: var(--muted); margin: 8px 2px; }
  .pipeline-text {
    margin: 12px 2px 2px;
    padding: 10px 12px;
    border-radius: 8px;
    background: var(--meter-track);
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px;
    line-height: 1.5;
    color: var(--text);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    user-select: text;
    -webkit-user-select: text;
  }
  .pipeline-text:empty { display: none; }
  .copy-btn {
    display: inline-block;
    margin: 10px 2px 2px;
    padding: 6px 14px;
    border: none;
    border-radius: 7px;
    background: var(--accent);
    color: #ffffff;
    font-family: inherit;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
  }
  .copy-btn:disabled {
    background: var(--meter-track);
    color: var(--muted);
    cursor: default;
  }
  .copy-btn:not(:disabled):hover { opacity: 0.85; }
  /* SVG pipeline */
  rect.node { fill: var(--node); stroke: var(--node-border); stroke-width: 1.5; }
  rect.node.stopped { stroke: var(--node-stopped-border); }
  circle.dot-run { fill: var(--on); }
  circle.dot-stop { fill: var(--off); }
  text.node-name { fill: var(--text); font-size: 13px; font-weight: 600; }
  text.node-detail { fill: var(--muted); font-size: 11px; }
  line.arrow { stroke: var(--arrow); stroke-width: 1.5; }
  line.arrow.udp { stroke: var(--udp); stroke-dasharray: 4 3; }
  path.arrowhead { fill: var(--arrow); }
  text.link-label { fill: var(--muted); font-size: 10px; font-weight: 600; text-transform: uppercase; }
  g.pnode { cursor: default; }
  /* Hover info panel */
  #tip {
    position: fixed;
    display: none;
    z-index: 10;
    max-width: 520px;
    padding: 12px 14px;
    border-radius: 10px;
    background: var(--card);
    border: 1px solid var(--card-border);
    box-shadow: 0 8px 28px rgba(0,0,0,0.28);
    pointer-events: none;
  }
  #tip .tip-head { font-weight: 600; font-size: 13px; }
  #tip .tip-sub { color: var(--muted); font-size: 11px; margin: 2px 0 10px; }
  #tip .tip-lbl {
    color: var(--muted);
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin-bottom: 3px;
  }
  #tip .tip-path {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px;
    line-height: 1.4;
    overflow-wrap: anywhere;
    margin-bottom: 10px;
  }
  #tip .tip-args { display: flex; flex-wrap: wrap; gap: 4px; }
  #tip .arg {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 11px;
    padding: 1px 6px;
    border-radius: 5px;
    background: var(--meter-track);
    overflow-wrap: anywhere;
  }
  #tip .tip-args.flag .arg.k { color: var(--accent); }
</style>
</head>
<body>
  <div class="wrap">
    <section class="card">
      <h2>Stream</h2>
      <div class="row"><span class="lbl">Server</span><span class="val"><span id="serverDot" class="dot off"></span><span id="serverState">—</span></span></div>
      <div class="row"><span class="lbl">Listeners</span><span class="val" id="listeners">—</span></div>
    </section>

    <section class="card">
      <h2>RTL-SDR Devices</h2>
      <div id="devices"><p class="idle">Scanning…</p></div>
    </section>

    <section class="card">
      <h2>Tuning</h2>
      <div class="row"><span class="lbl">Status</span><span class="val" id="statusFunction">—</span></div>
      <div class="row"><span class="lbl">Station</span><span class="val" id="stationName">—</span></div>
      <div class="row"><span class="lbl">Frequency</span><span class="val" id="frequency">—</span></div>
      <div class="row"><span class="lbl">Modulation</span><span class="val" id="modulation">—</span></div>
      <div class="row"><span class="lbl">Sampling Mode</span><span class="val" id="samplingMode">—</span></div>
    </section>

    <section class="card">
      <h2>Radio</h2>
      <div class="row"><span class="lbl">Signal</span><span class="val meter"><span id="signalFill"></span></span></div>
      <div class="row"><span class="lbl">Squelch Level</span><span class="val" id="squelch">—</span></div>
      <div class="row"><span class="lbl">Tuner Gain</span><span class="val" id="tunerGain">—</span></div>
      <div class="row"><span class="lbl">Tuner AGC</span><span class="val" id="tunerAGC">—</span></div>
      <div class="row"><span class="lbl">Sample Rate</span><span class="val" id="sampleRate">—</span></div>
      <div class="row"><span class="lbl">Audio Filter</span><span class="val" id="audioFilter">—</span></div>
      <div class="row"><span class="lbl">rtl_fm Options</span><span class="val" id="options">—</span></div>
    </section>

    <section class="card full">
      <h2>Pipeline</h2>
      <div class="row"><span class="lbl">Last Started</span><span class="val" id="pipelineStarted">—</span></div>
      <div class="row"><span class="lbl">Last Stopped</span><span class="val" id="pipelineStopped">—</span></div>
      <div id="pipeline"></div>
      <pre id="pipelineText" class="pipeline-text"></pre>
      <button id="copyPipelineBtn" class="copy-btn" onclick="copyPipelineText()" disabled title="Copy the pipeline as `|`-joined CLI text — paste it into a ControlBooth pipeline's stage list.">Copy Pipeline</button>
    </section>
  </div>

  <div id="tip"></div>

<script>
function esc(s){ return (s == null ? '' : String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

function setText(id, v){
  var e = document.getElementById(id);
  if (!e) return;
  e.textContent = (v === undefined || v === null || v === '') ? '—' : v;
}

function buildPipeline(stages){
  var c = document.getElementById('pipeline');
  if (!stages || !stages.length){
    c.innerHTML = '<p class="idle">Pipeline idle — no tasks running.</p>';
    return;
  }
  var NW = 178, NH = 78, GAP = 54, PADX = 14, TOP = 26, BOT = 14;
  var W = PADX * 2 + stages.length * NW + (stages.length - 1) * GAP;
  var H = TOP + NH + BOT;
  var p = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="' + W + '" height="' + H + '" xmlns="http://www.w3.org/2000/svg">';
  p += '<defs><marker id="ah" markerWidth="9" markerHeight="9" refX="7" refY="3" orient="auto"><path d="M0,0 L7,3 L0,6 Z" class="arrowhead"/></marker></defs>';
  for (var i = 0; i < stages.length; i++){
    var s = stages[i];
    var x = PADX + i * (NW + GAP);
    var y = TOP;
    var midY = y + NH / 2;
    if (i > 0){
      var x1 = x - GAP, x2 = x;
      var udp = String(s.link || '').toUpperCase().indexOf('UDP') === 0;
      p += '<line x1="' + x1 + '" y1="' + midY + '" x2="' + (x2 - 3) + '" y2="' + midY + '" class="arrow' + (udp ? ' udp' : '') + '" marker-end="url(#ah)"/>';
      if (s.link){
        p += '<text x="' + ((x1 + x2) / 2) + '" y="' + (midY - 8) + '" class="link-label" text-anchor="middle">' + esc(s.link) + '</text>';
      }
    }
    p += '<g class="pnode" data-i="' + i + '">';
    p += '<rect x="' + x + '" y="' + y + '" width="' + NW + '" height="' + NH + '" rx="12" class="node' + (s.running ? '' : ' stopped') + '"/>';
    p += '<circle cx="' + (x + NW - 18) + '" cy="' + (y + 18) + '" r="5" class="' + (s.running ? 'dot-run' : 'dot-stop') + '"/>';
    p += '<text x="' + (x + 16) + '" y="' + (y + 32) + '" class="node-name">' + esc(s.name) + '</text>';
    p += '<text x="' + (x + 16) + '" y="' + (y + 54) + '" class="node-detail">' + esc(s.detail) + '</text>';
    p += '</g>';
  }
  p += '</svg>';
  c.innerHTML = p;

  // Attach hover handlers that surface the full path + arguments.
  window.__stages = stages;
  var nodes = c.querySelectorAll('g.pnode');
  for (var n = 0; n < nodes.length; n++){
    nodes[n].addEventListener('mouseenter', function(e){ showTip(window.__stages[+this.getAttribute('data-i')], e); });
    nodes[n].addEventListener('mousemove', moveTip);
    nodes[n].addEventListener('mouseleave', hideTip);
  }
}

function showTip(stage, evt){
  if (!stage) return;
  var t = document.getElementById('tip');
  var h = '<div class="tip-head">' + esc(stage.name) + '</div>';
  h += '<div class="tip-sub">' + esc(stage.detail) + '</div>';
  h += '<div class="tip-lbl">Path</div>';
  h += '<div class="tip-path">' + esc(stage.path) + '</div>';
  if (stage.args && stage.args.length){
    h += '<div class="tip-lbl">Arguments</div><div class="tip-args">';
    for (var i = 0; i < stage.args.length; i++){
      var a = stage.args[i];
      var cls = (a.charAt(0) === '-') ? 'arg k' : 'arg';
      h += '<span class="' + cls + '">' + esc(a) + '</span>';
    }
    h += '</div>';
  }
  t.innerHTML = h;
  t.style.display = 'block';
  moveTip(evt);
}

function moveTip(evt){
  var t = document.getElementById('tip');
  if (t.style.display !== 'block') return;
  var pad = 14;
  var w = t.offsetWidth, h = t.offsetHeight;
  var x = evt.clientX + 16;
  var y = evt.clientY + 16;
  if (x + w + pad > window.innerWidth) x = evt.clientX - w - 16;
  if (y + h + pad > window.innerHeight) y = window.innerHeight - h - pad;
  if (x < pad) x = pad;
  if (y < pad) y = pad;
  t.style.left = x + 'px';
  t.style.top = y + 'px';
}

function hideTip(){
  document.getElementById('tip').style.display = 'none';
}

// Classic hidden-textarea copy: works inside a WKWebView loaded via
// loadHTMLString (null origin), where navigator.clipboard.writeText can be
// refused for lacking a secure context.
function copyPipelineText(){
  var text = window.__pipelineCLIText || '';
  if (!text) return;
  var ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.left = '-9999px';
  document.body.appendChild(ta);
  ta.focus();
  ta.select();
  try { document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(ta);
}

function buildDevices(devices){
  var c = document.getElementById('devices');
  if (!devices || !devices.length){
    c.innerHTML = '<p class="idle">No devices detected.</p>';
    return;
  }
  var h = '';
  for (var i = 0; i < devices.length; i++){
    var d = devices[i];
    h += '<div class="row"><span class="lbl">Device ' + d.index + '</span><span class="val">';
    if (d.serial){
      h += esc(d.serial);
      if (d.product) h += ' <span style="color:var(--muted);font-weight:400">(' + esc(d.product) + ')</span>';
    } else {
      h += esc(d.name) || '—';
    }
    h += '</span></div>';
  }
  c.innerHTML = h;
}

function applyStatus(s){
  var live = !!s.serverRunning;
  var dot = document.getElementById('serverDot');
  if (dot) dot.className = 'dot ' + (live ? 'on' : 'off');
  setText('serverState', live ? 'Live' : 'Offline');
  setText('listeners', s.listenerCount + ' listener' + (s.listenerCount === 1 ? '' : 's'));
  setText('statusFunction', s.statusFunction);
  setText('stationName', s.stationName);
  setText('frequency', s.frequencyDisplay);
  setText('modulation', s.modulation);
  setText('samplingMode', s.samplingMode);
  setText('squelch', s.squelchLevel);
  setText('tunerGain', s.tunerGain);
  setText('tunerAGC', s.tunerAGC ? 'On' : 'Off');
  setText('sampleRate', s.sampleRate);
  setText('audioFilter', s.audioOutputFilter);
  setText('options', s.options);
  setText('pipelineStarted', s.pipelineLastStarted);
  setText('pipelineStopped', s.pipelineLastStopped);
  var textEl = document.getElementById('pipelineText');
  if (textEl) textEl.textContent = s.pipelineText || '';
  window.__pipelineCLIText = s.pipelineCLIText || '';
  var copyBtn = document.getElementById('copyPipelineBtn');
  if (copyBtn) copyBtn.disabled = !s.pipelineCLIText;
  var fill = document.getElementById('signalFill');
  if (fill) fill.style.width = Math.round((s.signalLevel || 0) * 100) + '%';
  // Device list changes rarely; only rebuild when content changes.
  var devicesJSON = JSON.stringify(s.devices || []);
  if (devicesJSON !== window.__lastDevicesJSON) {
    window.__lastDevicesJSON = devicesJSON;
    buildDevices(s.devices);
  }
  // The signal level pushes updates several times a second; only rebuild the
  // pipeline SVG when the stages actually change (avoids churn + hover flicker).
  var stagesJSON = JSON.stringify(s.stages || []);
  if (stagesJSON !== window.__lastStagesJSON) {
    window.__lastStagesJSON = stagesJSON;
    buildPipeline(s.stages);
  }
}
</script>
</body>
</html>
"""#
}
