// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// injector.mjs — CDP runtime injector for official Bilibili PC client
// Does NOT modify app.asar. Requires launcher with --remote-debugging-port=9222

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.BSB_CDP_PORT || 9222);
const PAYLOAD_DIR = process.env.BSB_PAYLOAD_DIR || path.join(ROOT, "payload");
const CONFIG_CANDIDATES = [
  path.join(process.env.LOCALAPPDATA || "", "bsb-client-patcher", "bsb-config.json"),
  path.join(PAYLOAD_DIR, "bsb-config.default.json")
];
const POLL_MS = 1500;          // idle poll
const POLL_FAST_MS = 300;      // while a page still needs injecting
const DEBUG = process.env.BSB_DEBUG === "1";
const LOG_FILE = process.env.BSB_LOG_FILE || "";
const COMMAND_FILE = path.join(process.env.LOCALAPPDATA || "", "bsb-client-patcher", "command.json");
const LIVE_CONFIG_FILE = path.join(process.env.LOCALAPPDATA || "", "bsb-client-patcher", "live-config.json");
let lastLiveDump = 0;

/** Console output is useless when launched hidden at logon, so mirror to a file. */
function logToFile(line) {
  if (!LOG_FILE) return;
  try {
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > 1024 * 1024) {
      fs.renameSync(LOG_FILE, LOG_FILE + ".1");
    }
    fs.appendFileSync(LOG_FILE, line + "\n");
  } catch (_) {}
}

function log(...args) {
  // local time: the installer and status.ps1 show local, so logs must match
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, "0");
  const t = `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`;
  const line = `[${t}] [bsb-injector] ${args.join(" ")}`;
  console.log(line);
  logToFile(line);
}

/**
 * Execute a command dropped by the installer app. The app cannot talk CDP itself,
 * and the injector already holds the page connections, so it does the work.
 */
/** Mirror the config a page is actually running to disk (the installer reads it). */
async function dumpLiveConfig(list) {
  const now = Date.now();
  if (now - lastLiveDump < 10000) return;
  lastLiveDump = now;
  for (const t of list) {
    if (!t.webSocketDebuggerUrl) continue;
    if (!/bilipc\.bilibili\.com|bilibili\.com/i.test(t.url || "")) continue;
    try {
      const raw = await evaluate(t.webSocketDebuggerUrl,
        "(function(){try{return localStorage.getItem('bsb_config')||''}catch(e){return ''}})()");
      const val = raw && raw.result && raw.result.value;
      if (!val) continue;
      const parsed = JSON.parse(val);
      const text = JSON.stringify(parsed);
      let prev = "";
      try { prev = fs.readFileSync(LIVE_CONFIG_FILE, "utf8"); } catch (_) {}
      if (prev.trim() !== text) fs.writeFileSync(LIVE_CONFIG_FILE, text);
      return;
    } catch (_) {}
  }
}

async function runCommand(list, cmd) {
  if (!cmd || !cmd.cmd) return false;
  if (cmd.cmd === "push-config" && cmd.config) {
    const expr = `(function(){
      try {
        var cfg = ${JSON.stringify(cmd.config)};
        localStorage.setItem("bsb_config", JSON.stringify(cfg));
        localStorage.setItem("bsb_config_t", String(Date.now()));
        if (window.__bsb && window.__bsb.config) { Object.assign(window.__bsb.config, cfg); }
        if (window.__bsb && window.__bsb.refresh) { window.__bsb.refresh(true); }
        if (window.__bsbUI && window.__bsbUI.refresh) { window.__bsbUI.refresh(); }
        return "ok";
      } catch (e) { return String(e); }
    })()`;
    let n = 0;
    for (const t of list) {
      if (!t.webSocketDebuggerUrl) continue;
      if (!/bilipc\.bilibili\.com|bilibili\.com/i.test(t.url || "")) continue;
      try { await evaluate(t.webSocketDebuggerUrl, expr); n++; } catch (_) {}
    }
    log("command push-config ->", n, "page(s)");
    return true;
  }
  if (cmd.cmd === "refresh-pages") {
    let n = 0;
    for (const t of list) {
      if (!t.webSocketDebuggerUrl) continue;
      if (!/bilipc\.bilibili\.com|bilibili\.com/i.test(t.url || "")) continue;
      try {
        await evaluate(t.webSocketDebuggerUrl, "(function(){try{window.__bsb&&window.__bsb.refresh(true);return 1}catch(e){return 0}})()");
        n++;
      } catch (_) {}
    }
    log("command refresh-pages ->", n, "page(s)");
    return true;
  }
  log("unknown command", cmd.cmd);
  return true;
}

function vcmp(a, b) {
  const pa = String(a || "0").split(".").map(Number);
  const pb = String(b || "0").split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0 ? 1 : -1;
  }
  return 0;
}

/**
 * Only one injector may run at a time: two instances with different in-memory
 * payloads create and delete the same DOM nodes on every poll, which shows up
 * as a flickering BSB button in the player.
 * Matched on the command line, not the image name - injectors launched from a
 * host app (e.g. the MiMo node runtime) are not called node.exe.
 */
function killOtherInjectors() {
  if (process.env.BSB_NO_KILL === "1" || process.platform !== "win32") return;
  const ps = [
    `$self = ${process.pid};`,
    // a launcher shell mentions injector.mjs on its command line too - keep it alive
    "$shells = @('powershell.exe','pwsh.exe','cmd.exe','bash.exe','sh.exe','wsl.exe','explorer.exe','windowsterminal.exe','conhost.exe');",
    "Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |",
    "Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -match 'injector\\.mjs' -and $shells -notcontains $_.Name } |",
    "ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $_.ProcessId } catch {} }"
  ].join(" ");
  try {
    const out = execFileSync("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps], {
      encoding: "utf8",
      timeout: 20000
    });
    const killed = out.trim().split(/\s+/).filter(Boolean);
    if (killed.length) log("stopped stale injector(s):", killed.join(", "));
  } catch (e) {
    log("stale-injector scan failed:", e && e.message);
  }
}

/** Files that make up a payload; used to notice edits that keep the same version. */
const PAYLOAD_FILES = ["bsb-content.js", "bsb-ui.js", "bsb-settings.js"];

function payloadSig(dir, version) {
  const parts = [version];
  for (const f of PAYLOAD_FILES) {
    try {
      const st = fs.statSync(path.join(dir, f));
      parts.push(`${f}:${st.size}:${Math.round(st.mtimeMs)}`);
    } catch (_) {
      parts.push(`${f}:-`);
    }
  }
  return parts.join("|");
}

function pickPayloadDir() {
  const candidates = [
    process.env.BSB_PAYLOAD_DIR,
    path.join(ROOT, "payload"),
    path.join(process.env.LOCALAPPDATA || "", "bsb-client-patcher", "payload")
  ].filter(Boolean);
  let best = null;
  let bestVer = "";
  for (const dir of candidates) {
    try {
      const mf = path.join(dir, "manifest.json");
      if (!fs.existsSync(path.join(dir, "bsb-ui.js"))) continue;
      let ver = "";
      try { ver = JSON.parse(fs.readFileSync(mf, "utf8")).version || ""; } catch (_) {}
      // also peek ui file version string
      try {
        const ui = fs.readFileSync(path.join(dir, "bsb-ui.js"), "utf8");
        const m = ui.match(/version:\s*["']([^"']+)["']/);
        if (m && vcmp(m[1], ver) > 0) ver = m[1];
      } catch (_) {}
      if (!best || vcmp(ver, bestVer) > 0) {
        best = dir;
        bestVer = ver;
      }
    } catch (_) {}
  }
  return { dir: best || path.join(ROOT, "payload"), ver: bestVer };
}

function readPayload() {
  const picked = pickPayloadDir();
  const PAYLOAD = picked.dir;
  const contentPath = path.join(PAYLOAD, "bsb-content.js");
  const uiPath = path.join(PAYLOAD, "bsb-ui.js");
  const settingsPath = path.join(PAYLOAD, "bsb-settings.js");
  const manifestPath = path.join(PAYLOAD, "manifest.json");
  if (!fs.existsSync(contentPath)) throw new Error("missing payload: " + contentPath);
  const content = fs.readFileSync(contentPath, "utf8");
  const ui = fs.existsSync(uiPath) ? fs.readFileSync(uiPath, "utf8") : "";
  const settings = fs.existsSync(settingsPath) ? fs.readFileSync(settingsPath, "utf8") : "";
  let version = picked.ver || "0.0.0";
  let config = null;
  try {
    const mv = JSON.parse(fs.readFileSync(manifestPath, "utf8")).version;
    if (mv && vcmp(mv, version) > 0) version = mv;
  } catch {}
  const configCandidates = [
    path.join(process.env.LOCALAPPDATA || "", "bsb-client-patcher", "bsb-config.json"),
    path.join(PAYLOAD, "bsb-config.default.json")
  ];
  for (const p of configCandidates) {
    try {
      if (fs.existsSync(p)) { config = JSON.parse(fs.readFileSync(p, "utf8")); break; }
    } catch {}
  }
  if (config) {
    config.showBadge = false;
    config.showSkipNotice = true;
  }
  // expose for logs
  global.__bsbPayloadMeta = { dir: PAYLOAD, version };
  return { content, ui, settings, version, config, dir: PAYLOAD, sig: payloadSig(PAYLOAD, version) };
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: 2000 }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (body += c));
      res.on("end", () => {
        try { resolve(JSON.parse(body)); } catch (e) { reject(e); }
      });
    });
    req.on("error", reject);
    req.on("timeout", () => { req.destroy(new Error("timeout")); });
  });
}

function evaluate(wsUrl, expression) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const done = (fn, arg) => {
      if (settled) return;
      settled = true;
      try { fn(arg); } catch {}
    };
    let ws;
    try {
      ws = new WebSocket(wsUrl);
    } catch (e) {
      return done(reject, e);
    }
    const id = 1;
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      done(reject, new Error("cdp timeout"));
    }, 8000);
    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({
        id,
        method: "Runtime.evaluate",
        params: { expression, returnByValue: true, awaitPromise: false, userGesture: false }
      }));
    });
    ws.addEventListener("message", (ev) => {
      try {
        const msg = JSON.parse(String(ev.data));
        if (msg.id === id) {
          clearTimeout(timer);
          try { ws.close(); } catch {}
          if (msg.error) done(reject, new Error(msg.error.message || "cdp error"));
          else done(resolve, msg.result);
        }
      } catch (e) {
        clearTimeout(timer);
        done(reject, e);
      }
    });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      done(reject, new Error("cdp ws error"));
    });
  });
}

function normalizeUrl(url) {
  try {
    const u = new URL(url);
    ["uuid", "cached", "mediaList", "cmFromTrackId", "fSpmid", "itemId"].forEach((k) => u.searchParams.delete(k));
    return u.origin + u.pathname + u.search + (u.hash || "");
  } catch (_) {
    return String(url || "");
  }
}

function buildExpression(payload) {
  const hostJson = JSON.stringify({
    config: payload.config,
    configSource: CONFIG_CANDIDATES.find((p) => fs.existsSync(p)) || null,
    version: payload.version,
    injector: "cdp"
  });
  const payloadUiVer = (() => {
    const m = (payload.ui || "").match(/version:\s*["']([^"']+)["']/);
    return m ? m[1] : payload.version;
  })();
  return [
    "(function(){",
    "function vcmp(a,b){var pa=String(a||'0').split('.').map(Number),pb=String(b||'0').split('.').map(Number);for(var i=0;i<Math.max(pa.length,pb.length);i++){var d=(pa[i]||0)-(pb[i]||0);if(d)return d>0?1:-1;}return 0;}",
    "var PV=" + JSON.stringify(payload.version) + ", UIPV=" + JSON.stringify(payloadUiVer) + ";",
    "var out=[];",
    // host info must be upgraded in place: an older injector may have set it first
    "var hv=(window.__BSB_HOST__&&window.__BSB_HOST__.version)||'';",
    "if(!window.__BSB_HOST__ || vcmp(hv,PV)<0){try{window.__BSB_HOST__=" + hostJson + ";}catch(e){}}",
    // re-run a layer only when the page runs an older build of it
    "var needContent=!window.__BSB_CONTENT_LOADED__ || vcmp(window.__BSB_CONTENT_VERSION__||'0.0.0',PV)<0;",
    "var needUi=!window.__BSB_UI_LOADED__ || vcmp((window.__bsbUI&&window.__bsbUI.version)||window.__BSB_UI_VERSION__||'0.0.0',UIPV)<0;",
    "var needSet=!window.__BSB_SETTINGS_LOADED__ || vcmp(window.__BSB_SETTINGS_VERSION__||'0.0.0',PV)<0;",
    // Only the loaded-flags are reset here. The payload's own tickers retire
    // themselves (they compare their version with the page's), because a ticker
    // killed from outside would leave the page without button/panel upkeep.
    "if(needUi){try{window.__BSB_UI_LOADED__=false;}catch(e){}}",
    "if(needSet){try{window.__BSB_SETTINGS_LOADED__=false;}catch(e){}}",
    "if(needContent){",
    "  try{window.__BSB_HOST__=" + hostJson + ";}catch(e){}",
    payload.content,
    "  if(window.__BSB_CONTENT_LOADED__) out.push('content');",
    "}",
    "if(!window.__BSB_UI_LOADED__){",
    payload.ui || "",
    "  if(window.__BSB_UI_LOADED__) out.push('ui');",
    "}",
    "if(!window.__BSB_SETTINGS_LOADED__){",
    payload.settings || "",
    "  if(window.__BSB_SETTINGS_LOADED__) out.push('settings');",
    "}",
    "return out.length?out.join('+'):'already';",
    "})()"
  ].join("\n");
}

function isInjectableTarget(t) {
  if (!t) return false;
  if (t.type && t.type !== "page" && t.type !== "webview") return false;
  const url = t.url || "";
  if (!url || url === "about:blank") return false;
  // skip devtools
  if (url.startsWith("devtools://")) return false;
  // bilipc / bilibili pages
  if (/bilipc\.bilibili\.com|bilibili\.com|file:\/\//i.test(url)) return true;
  // native windows sometimes load custom schemes
  if (/^https?:/i.test(url)) return true;
  return false;
}

async function openSettingsOnIndex(list, payload) {
  const indexPage = (list || []).find((t) => (t.url || "").includes("index.html") && t.webSocketDebuggerUrl);
  if (!indexPage) return false;
  const expr =
    "(function(){try{" +
    "location.hash='#/page/settings';" +
    "localStorage.removeItem('bsb_open_settings');" +
    "setTimeout(function(){try{window.__bsbSettings&&window.__bsbSettings.open&&window.__bsbSettings.open()}catch(e){}},400);" +
    "return 'ok'}catch(e){return String(e)}})()";
  try {
    await evaluate(indexPage.webSocketDebuggerUrl, expr);
  } catch (e) {
    if (DEBUG) log("open settings nav fail", e && e.message);
  }
  // Bring main index window to front so click feels responsive
  try {
    if (indexPage.id) {
      await cdpRaw(indexPage.webSocketDebuggerUrl, "Target.activateTarget", { targetId: indexPage.id });
    }
  } catch (e) {
    if (DEBUG) log("activate fail", e && e.message);
  }
  // Also try page bring-to-front via CDP on that target's browser connection
  try {
    await evaluate(indexPage.webSocketDebuggerUrl, "(function(){try{window.focus();return 'focus'}catch(e){return ''}})()");
  } catch (_) {}
  log("opened official settings -> BSB panel + activate index window");
  return true;
}

/** low-level CDP method call */
function cdpRaw(wsUrl, method, params) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const id = 1;
    const timer = setTimeout(() => { try { ws.close(); } catch {} reject(new Error("cdp " + method + " timeout")); }, 5000);
    ws.addEventListener("open", () => ws.send(JSON.stringify({ id, method, params })));
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(String(ev.data));
      if (msg.id === id) { clearTimeout(timer); try { ws.close(); } catch {} resolve(msg); }
    });
    ws.addEventListener("error", () => { clearTimeout(timer); reject(new Error("cdp ws " + method)); });
  });
}

async function main() {
  killOtherInjectors();
  let payload = readPayload();
  log("payload", JSON.stringify(global.__bsbPayloadMeta), "v" + payload.version); try{require("fs").writeFileSync(require("path").join(require("os").tmpdir(),"bsb-injector-meta.json"), JSON.stringify(global.__bsbPayloadMeta))}catch(e){}
  let lastCount = -1;
  let lastOpenFlag = 0;
  let lastCommandId = "";
  let lastPayloadCheck = 0;

  for (;;) {
    // re-read payload every 3s so file updates apply without restart
    const now = Date.now();
    if (now - lastPayloadCheck > 3000) {
      lastPayloadCheck = now;
      try {
        const next = readPayload();
        if (next.sig !== payload.sig) {
          payload = next;
          log("payload reloaded v" + payload.version, payload.dir);
        }
      } catch (_) {}
    }

    let list = [];
    try {
      list = await fetchJson(`http://127.0.0.1:${PORT}/json/list`);
    } catch (_) {}

    if (Array.isArray(list) && list.length !== lastCount) {
      log("targets", list.length);
      lastCount = list.length;
    }

    // Ask every page what it is running instead of remembering it here: a
    // reloaded page keeps the same target id, so a local "already injected"
    // map would silently skip it forever. The payload's version gates make the
    // evaluation a cheap no-op once a page is current.
    let needsFollowUp = false;
    for (const t of list) {
      if (!isInjectableTarget(t)) continue;
      if (!t.webSocketDebuggerUrl) continue;

      try {
        const result = await evaluate(t.webSocketDebuggerUrl, buildExpression(payload));
        const val = result && result.result && result.result.value;
        if (val !== "already") {
          needsFollowUp = true;
          log("inject", val, normalizeUrl(t.url), "v" + payload.version);
        } else if (DEBUG) {
          log("up-to-date", normalizeUrl(t.url));
        }
      } catch (e) {
        if (DEBUG) log("fail", normalizeUrl(t.url), e && e.message);
      }
    }

    try {
      const player = list.find((t) => (t.url || "").includes("player.html") && t.webSocketDebuggerUrl);
      if (player) {
        const r = await evaluate(
          player.webSocketDebuggerUrl,
          "(function(){try{return localStorage.getItem('bsb_open_settings')||''}catch(e){return ''}})()"
        );
        const flag = r && r.result && r.result.value;
        const n = Number(flag || 0);
        if (n && n !== lastOpenFlag) {
          lastOpenFlag = n;
          await openSettingsOnIndex(list, payload);
        }
      }
    } catch (_) {}

    await dumpLiveConfig(list);

    // commands dropped by the installer app
    try {
      if (fs.existsSync(COMMAND_FILE)) {
        const raw = fs.readFileSync(COMMAND_FILE, "utf8");
        const cmd = JSON.parse(raw);
        if (cmd && cmd.id && cmd.id !== lastCommandId) {
          lastCommandId = cmd.id;
          await runCommand(list, cmd);
          try { fs.unlinkSync(COMMAND_FILE); } catch (_) {}
        }
      }
    } catch (e) {
      if (DEBUG) log("command failed", e && e.message);
      try { fs.unlinkSync(COMMAND_FILE); } catch (_) {}
    }

    // Poll fast right after a page needed work (fresh window, payload update),
    // idle otherwise.
    await new Promise((r) => setTimeout(r, needsFollowUp ? POLL_FAST_MS : POLL_MS));
  }
}

process.on("uncaughtException", (e) => {
  log("uncaught", e && e.message);
});
process.on("unhandledRejection", (e) => {
  if (DEBUG) log("unhandled", e);
});

log("starting...");
main().catch((e) => {
  log("fatal", e && e.message);
  process.exit(1);
});
