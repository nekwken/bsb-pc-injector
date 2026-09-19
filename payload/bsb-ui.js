// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// Derived from BilibiliSponsorBlock (GPL-3.0) — see NOTICE.md
//
// bsb-ui.js — player UI for official PC client (bpx player)
// Keep: preview bar + BSB button + floating panel on click + skip notice (temporary)
// Remove: permanent bottom-right status badge
// Official settings page: bsb-settings.js

(function () {
    "use strict";
    if (window.__BSB_UI_LOADED__) return;
    window.__BSB_UI_LOADED__ = true;

    const VERSION = "0.4.6";

    try {
        const badge = document.getElementById("bsb-status-badge");
        if (badge) badge.remove();
        document.querySelectorAll("#bsb-status-badge").forEach(function (el) {
            try { el.remove(); } catch (_) {}
        });
    } catch (_) {}

    const CATEGORY = {
        sponsor: { color: "#00d400", label: "广告" },
        selfpromo: { color: "#ffff00", label: "无偿推广" },
        exclusive_access: { color: "#010101", label: "品牌合作" },
        interaction: { color: "#cc00ff", label: "三连/订阅提醒" },
        intro: { color: "#00ffff", label: "开场动画" },
        outro: { color: "#0000ff", label: "片尾/鸣谢" },
        preview: { color: "#008000", label: "预告/回顾" },
        filler: { color: "#7300ff", label: "离题闲聊" },
        music_offtopic: { color: "#ff9900", label: "非音乐部分" },
        poi_highlight: { color: "#ff1684", label: "精彩时刻" },
        padding: { color: "#c0c0c0", label: "填充片段" }
    };
    const ACTION_LABEL = { skip: "跳过", mute: "静音", full: "整段标签", poi: "高光" };

    function catInfo(c) {
        return CATEGORY[c] || { color: "#00d400", label: c || "片段" };
    }

    function fmtTime(t) {
        if (!isFinite(t)) return "--:--";
        t = Math.max(0, Math.floor(t));
        const h = Math.floor(t / 3600);
        const m = Math.floor((t % 3600) / 60);
        const s = t % 60;
        const mm = String(m).padStart(2, "0");
        const ss = String(s).padStart(2, "0");
        return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss;
    }

    function playerMountRoot() {
        // Prefer documentElement/body so player re-renders do not wipe the panel.
        // Fullscreen: only descendants of fullscreenElement are visible → mount there.
        const fsEl = document.fullscreenElement;
        if (fsEl) return fsEl;
        return document.documentElement || document.body;
    }

    function mountFloat(el) {
        if (!el) return;
        const root = playerMountRoot();
        if (el.parentElement !== root) {
            try { root.appendChild(el); } catch (_) {
                try { document.body.appendChild(el); } catch (__) {}
            }
        }
        // The player window can be small (a mini/short window is only ~180px tall);
        // a fixed 360px panel anchored at bottom would land above the viewport.
        const vw = window.innerWidth || 1280;
        const vh = window.innerHeight || 720;
        const M = 8;
        if (el.id === "bsb-panel") {
            const w = Math.max(200, Math.min(300, vw - 2 * M));
            const h = Math.max(120, Math.min(360, vh - 88));
            el.style.position = "fixed";
            el.style.width = w + "px";
            el.style.maxHeight = h + "px";
            el.style.left = Math.max(M, vw - w - 16) + "px";
            el.style.top = Math.max(M, vh - h - 72) + "px";
            el.style.right = "auto";
            el.style.bottom = "auto";
            el.style.zIndex = "2147483000";
        }
        if (el.id === "bsb-skip-notice") {
            el.style.position = "fixed";
            el.style.left = "50%";
            el.style.transform = "translateX(-50%)";
            // keep the notice clear of the control bar in short windows
            if (vh < 320) {
                el.style.top = M + "px";
                el.style.bottom = "auto";
            } else {
                el.style.bottom = "86px";
                el.style.top = "auto";
            }
            el.style.zIndex = "2147483000";
        }
    }

    function reparentFloats() {
        try {
            const panel = document.getElementById("bsb-panel");
            const notice = document.getElementById("bsb-skip-notice");
            if (panel) mountFloat(panel);
            if (notice) mountFloat(notice);
            // player container needs positioning context for absolute children
            const root = playerMountRoot();
            if (root && root !== document.body) {
                const cs = getComputedStyle(root);
                if (cs.position === "static") root.style.position = "relative";
            }
        } catch (_) {}
    }

    document.addEventListener("fullscreenchange", function () {
        setTimeout(reparentFloats, 50);
    });
    document.addEventListener("webkitfullscreenchange", function () {
        setTimeout(reparentFloats, 50);
    });

    const CSS = `
#bsb-preview-bar{position:absolute;left:0;right:0;top:0;height:4px;bottom:auto;pointer-events:none;z-index:6}
#bsb-preview-bar .seg{position:absolute;top:0;height:4px;bottom:auto;opacity:.78;min-width:2px;border-radius:1px;box-sizing:border-box}
#bsb-preview-bar .seg:hover{opacity:1}
#bsb-ctrl-btn{display:flex;align-items:center;justify-content:center;box-sizing:border-box;height:22px;min-width:36px;margin:0 8px;padding:0 8px;border-radius:4px;background:rgba(255,255,255,.12);color:#fff;font:12px/1 system-ui,sans-serif;letter-spacing:.5px;cursor:pointer;user-select:none;pointer-events:auto;opacity:.85;transition:background .15s,opacity .15s}
#bsb-ctrl-btn:hover{opacity:1;background:#00a1d6}
#bsb-ctrl-btn.bsb-active{background:#00a1d6;opacity:1}
#bsb-skip-notice{min-width:260px;max-width:420px;padding:10px 12px;border-radius:8px;background:rgba(20,20,24,.92);color:#fff;font:12px/1.45 system-ui,sans-serif;border:1px solid rgba(255,255,255,.12);box-shadow:0 6px 24px rgba(0,0,0,.35);display:none}
#bsb-skip-notice .title{font-weight:600;margin-bottom:4px;display:flex;align-items:center;gap:6px}
#bsb-skip-notice .dot{width:8px;height:8px;border-radius:50%;display:inline-block}
#bsb-skip-notice .meta{opacity:.85;margin-bottom:8px}
#bsb-skip-notice .actions{display:flex;gap:8px;justify-content:flex-end}
#bsb-skip-notice button{cursor:pointer;border:0;border-radius:4px;padding:4px 10px;font-size:12px;background:#3a3a42;color:#fff}
#bsb-skip-notice button.primary{background:#00a1d6}
#bsb-panel{width:300px;max-height:360px;overflow:auto;background:rgba(18,18,22,.94);color:#fff;border:1px solid rgba(255,255,255,.12);border-radius:10px;font:12px/1.45 system-ui,sans-serif;display:none;box-shadow:0 8px 28px rgba(0,0,0,.4)}
#bsb-panel .hd{display:flex;justify-content:space-between;align-items:center;padding:10px 12px;border-bottom:1px solid rgba(255,255,255,.08);font-weight:600}
#bsb-panel .hd .x{cursor:pointer;opacity:.7;padding:0 4px}
#bsb-panel .hd .x:hover{opacity:1}
#bsb-panel .bd{padding:8px 10px}
#bsb-panel .empty{opacity:.65;padding:8px}
#bsb-panel .seg-item{display:flex;align-items:center;gap:8px;padding:6px 4px;border-radius:6px;cursor:pointer}
#bsb-panel .seg-item:hover{background:rgba(255,255,255,.06)}
#bsb-panel .swatch{width:10px;height:10px;border-radius:2px;flex:none}
#bsb-panel .time{opacity:.8;font-variant-numeric:tabular-nums;margin-left:auto}
#bsb-panel .cats{margin-top:10px;padding-top:8px;border-top:1px solid rgba(255,255,255,.08)}
#bsb-panel .cats .t{opacity:.7;margin-bottom:6px}
#bsb-panel label{display:flex;align-items:center;gap:6px;margin:3px 0;cursor:pointer}
#bsb-panel .foot{margin-top:8px;display:flex;gap:8px;justify-content:flex-end}
#bsb-panel .foot button{border:0;border-radius:4px;padding:4px 10px;cursor:pointer;background:#00a1d6;color:#fff}
#bsb-panel .foot button.secondary{background:#3a3a42}
#bsb-panel .hd .hdr-r{display:flex;align-items:center;gap:8px}
#bsb-panel .hd .save-state{font-size:11px;font-weight:400;white-space:nowrap;opacity:.95}
#bsb-panel .hd .save-state.dirty{color:#ffd666}
#bsb-panel .hd .save-state.saved{color:#5bd47a}
#bsb-panel .foot button.dirty{box-shadow:inset 0 0 0 1px #ffd666}
`;

    function injectStyles() {
        let st = document.getElementById("bsb-ui-style");
        // an older build's stylesheet must be replaced, not reused: its rules
        // (e.g. hiding the button) would otherwise stay in force forever
        if (st && st.getAttribute("data-bsb-ver") === VERSION) return;
        if (!st) {
            st = document.createElement("style");
            st.id = "bsb-ui-style";
            (document.head || document.documentElement).appendChild(st);
        }
        st.textContent = CSS;
        st.setAttribute("data-bsb-ver", VERSION);
    }

    /** The player rebuilds its chrome (control bar, progress area) on seeks,
     *  quality switches and window changes, which drops our nodes. Chromium also
     *  throttles timers in hidden player windows (~1/s), so upkeep cannot rely on
     *  the ticker alone - a DOM observer puts the nodes back. */
    let playerObserver = null;
    let repairTimer = null;

    /** Deferred, coalesced repair. Runs as a macrotask so a mutation caused by
     *  the repair itself can never re-enter the observer synchronously. */
    function scheduleUiRepair() {
        if (repairTimer) return;
        repairTimer = setTimeout(function () {
            repairTimer = null;
            repairUi();
        }, 120);
    }

    function repairUi() {
        try { ensureControlButton(); } catch (_) {}
        try { ensurePreviewBar(); } catch (_) {}
    }

    /** Re-attach the segment bar; renderPreviewBar keeps its own cache so this
     *  stays a no-op once the bar is in place. */
    function ensurePreviewBar() {
        if (!window.__bsb) return;
        renderPreviewBar(window.__bsb.segments || []);
    }

    function watchPlayer() {
        try {
            if (playerObserver) playerObserver.disconnect();
            // Must contain both the progress area and the control bar.
            const target =
                document.querySelector(".bpx-player-primary-area") ||
                document.querySelector(".bpx-player-container") ||
                document.querySelector(".bpx-player-control-wrap") ||
                document.body;
            if (!target) return;
            playerObserver = new MutationObserver(function () {
                scheduleUiRepair();
            });
            playerObserver.observe(target, { childList: true, subtree: true });
            window.__bsbPlayerObserver = playerObserver;
        } catch (_) {}
    }

    function getProgressWrap() {
        return (
            document.querySelector(".bpx-player-progress") ||
            document.querySelector(".bpx-player-progress-schedule") ||
            document.querySelector(".bpx-player-progress-schedule-wrap") ||
            document.querySelector(".bpx-player-progress-area")
        );
    }

    function getDuration() {
        const v = document.querySelector("video");
        return v && v.duration && isFinite(v.duration) ? v.duration : 0;
    }

    let previewEl = null;
    function ensurePreviewHost() {
        const wrap = getProgressWrap();
        if (!wrap) return null;
        const cs = getComputedStyle(wrap);
        if (cs.position === "static") wrap.style.position = "relative";
        if (!previewEl || !previewEl.isConnected || previewEl.parentElement !== wrap) {
            const stale = document.querySelectorAll("#bsb-preview-bar");
            stale.forEach(function (el) {
                if (el.parentElement !== wrap) { try { el.remove(); } catch (_) {} }
            });
            previewEl = wrap.querySelector("#bsb-preview-bar") || document.createElement("div");
            previewEl.id = "bsb-preview-bar";
            wrap.appendChild(previewEl);
        }
        previewEl.style.height = "4px";
        previewEl.style.maxHeight = "4px";
        previewEl.style.top = "0";
        previewEl.style.bottom = "auto";
        return previewEl;
    }

    let lastPreviewSig = "";
    function renderPreviewBar(segments) {
        const host = ensurePreviewHost();
        if (!host) return;
        const dur = getDuration();
        const sig = (segments || []).map(function (s) {
            return [s.start, s.end, s.category, s.actionType].join(":");
        }).join("|") + "@" + Math.round(dur);
        if (sig === lastPreviewSig && host.childElementCount > 0) return;
        lastPreviewSig = sig;
        host.innerHTML = "";
        if (!segments || !segments.length || !dur) return;
        segments.forEach(function (seg) {
            const meta = catInfo(seg.category);
            const el = document.createElement("div");
            el.className = "seg";
            const left = (seg.start / dur) * 100;
            const width = Math.max(((seg.end - seg.start) / dur) * 100, 0.25);
            el.style.left = left + "%";
            el.style.width = width + "%";
            el.style.background = meta.color;
            el.style.height = "4px";
            el.style.top = "0";
            el.title = meta.label + " " + fmtTime(seg.start) + " - " + fmtTime(seg.end) +
                " · " + (ACTION_LABEL[seg.actionType] || seg.actionType || "");
            host.appendChild(el);
        });
    }

    // ---------- temporary skip notice (not permanent) ----------
    let noticeEl = null;
    let noticeTimer = null;
    let lastSkip = null;

    function ensureNotice() {
        if (!noticeEl || !noticeEl.isConnected) {
            noticeEl = document.getElementById("bsb-skip-notice");
        }
        if (!noticeEl) {
            noticeEl = document.createElement("div");
            noticeEl.id = "bsb-skip-notice";
            noticeEl.innerHTML =
                '<div class="title"><span class="dot"></span><span class="tt"></span></div>' +
                '<div class="meta"></div>' +
                '<div class="actions">' +
                '<button type="button" class="btn-panel">面板</button>' +
                '<button type="button" class="btn-undo primary">撤销跳过</button>' +
                "</div>";
            noticeEl.addEventListener("click", function (e) {
                e.stopPropagation();
            });
        }
        // Delegated: the node may survive from an older build whose own listeners
        // would otherwise still be the only ones attached.
        if (noticeEl.getAttribute("data-bsb-ver") !== VERSION) {
            noticeEl.setAttribute("data-bsb-ver", VERSION);
            noticeEl.addEventListener("click", function (e) {
                const t = e.target;
                if (!t || !t.closest) return;
                if (t.closest(".btn-undo")) {
                    e.stopPropagation();
                    onUndo();
                } else if (t.closest(".btn-panel")) {
                    e.stopPropagation();
                    noticeEl.style.display = "none";
                    togglePanel();
                }
            });
        }
        mountFloat(noticeEl);
        return noticeEl;
    }

    function showNotice(payload) {
        const el = ensureNotice();
        const meta = catInfo(payload.category);
        lastSkip = payload;
        el.querySelector(".dot").style.background = meta.color;
        el.querySelector(".tt").textContent = "空降助手 · " + meta.label;
        const action = ACTION_LABEL[payload.actionType] || payload.actionType || "skip";
        el.querySelector(".meta").textContent =
            action + " " + fmtTime(payload.start) + " - " + fmtTime(payload.end);
        mountFloat(el);
        el.style.display = "block";
        if (noticeTimer) clearTimeout(noticeTimer);
        noticeTimer = setTimeout(function () {
            el.style.display = "none";
        }, 4000);
    }

    function onUndo() {
        if (!lastSkip) return;
        const v = document.querySelector("video");
        if (!v) return;
        try { v.currentTime = Math.max(0, lastSkip.start - 0.05); } catch (_) {}
        if (lastSkip.actionType === "mute") {
            try { v.muted = false; } catch (_) {}
        }
        if (noticeEl) {
            noticeEl.querySelector(".meta").textContent = "已回到 " + fmtTime(lastSkip.start);
        }
    }

    // ---------- floating panel on button click ----------
    let panelEl = null;

    /** The panel currently in the document. The cached node goes stale whenever
     *  the player re-renders, and reading a detached node reports the wrong state. */
    function panelNode() {
        if (panelEl && panelEl.isConnected) return panelEl;
        panelEl = document.getElementById("bsb-panel");
        return panelEl;
    }

    // Panel skeleton. HEADER_INNER is what goes *inside* .hd - writing the whole
    // skeleton into .hd would nest a second .hd/.bd and double the footer.
    const HEADER_INNER =
        '<span>空降助手</span><span class="hdr-r"><span class="save-state" id="bsb-save-state"></span><span class="x" title="关闭">×</span></span>';
    const PANEL_HTML = '<div class="hd">' + HEADER_INNER + '</div><div class="bd"></div>';

    function ensurePanel() {
        panelEl = panelNode();
        // An older build could have created its own #bsb-panel while its cache was
        // stale; two nodes with the same id would render twice and fight.
        try {
            const all = document.querySelectorAll("#bsb-panel");
            if (all.length > 1) {
                all.forEach(function (el) { if (el !== panelEl) { try { el.remove(); } catch (_) {} } });
            }
        } catch (_) {}

        if (!panelEl) {
            panelEl = document.createElement("div");
            panelEl.id = "bsb-panel";
            panelEl.innerHTML = PANEL_HTML;
            panelEl.addEventListener("click", function (e) {
                e.stopPropagation();
            });
            panelEl.addEventListener("mousedown", function (e) {
                e.stopPropagation();
            });
        } else {
            const doubled = panelEl.querySelectorAll(".bd").length !== 1 || panelEl.querySelectorAll(".hd").length !== 1;
            if (doubled) {
                panelEl.innerHTML = PANEL_HTML;   // repair a panel built by a broken build
            } else if (panelEl.getAttribute("data-bsb-hdr") !== VERSION) {
                // the status text lives in the header so the footer never reflows
                const hd = panelEl.querySelector(".hd");
                if (hd) hd.innerHTML = HEADER_INNER;
            }
        }
        panelEl.setAttribute("data-bsb-hdr", VERSION);

        // Delegated close: a panel node kept from an older build still carries that
        // build's listeners, and those only hide the node without dropping the flag.
        if (panelEl.getAttribute("data-bsb-ver") !== VERSION) {
            panelEl.setAttribute("data-bsb-ver", VERSION);
            panelEl.addEventListener("click", function (e) {
                const t = e.target;
                if (t && t.closest && t.closest(".x")) {
                    e.stopPropagation();
                    closePanel();
                }
            });
        }
        mountFloat(panelEl);
        return panelEl;
    }

    function getEffectiveConfig() {
        const api = window.__bsb;
        if (api && api.config) return api.config;
        try {
            return JSON.parse(localStorage.getItem("bsb_config") || "{}");
        } catch (_) {
            return {};
        }
    }

    function saveConfigPatch(patch) {
        let base = {};
        try { base = JSON.parse(localStorage.getItem("bsb_config") || "{}"); } catch (_) {}
        const merged = Object.assign({}, base, patch);
        if (patch.categories) {
            merged.categories = Object.assign({}, (base.categories || {}), patch.categories);
        }
        if (patch.actionPreferences) {
            merged.actionPreferences = Object.assign({}, (base.actionPreferences || {}), patch.actionPreferences);
        }
        merged.showBadge = false;
        merged.showSkipNotice = true;
        try { localStorage.setItem("bsb_config", JSON.stringify(merged)); } catch (_) {}
        try {
            if (window.__bsb && window.__bsb.config) {
                Object.assign(window.__bsb.config, merged);
            }
        } catch (_) {}
        try { localStorage.setItem("bsb_config_t", String(Date.now())); } catch (_) {}
    }

    // ---- staged edits from the floating panel ----
    let pendingCats = null;   // { category: bool } not yet written to config
    let saveNotice = null;    // { text } shown until the next edit or panel close

    function saveStateText() {
        if (saveNotice) return saveNotice.text;
        if (pendingCats) return "未保存";
        return "";
    }

    function updateSaveState() {
        const panel = panelNode();
        const el = (panel && panel.querySelector(".save-state")) || document.getElementById("bsb-save-state");
        if (!el) return;
        el.textContent = saveStateText();
        el.className = saveStateClass();
    }

    function saveStateClass() {
        if (saveNotice) return "save-state saved";
        if (pendingCats) return "save-state dirty";
        return "save-state";
    }

    /** Write the staged category switches and tell the user it stuck. */
    function commitPanelChanges() {
        if (!pendingCats) {
            saveNotice = { text: "无改动" };
            renderPanel();
            return;
        }
        saveConfigPatch({ categories: pendingCats });
        pendingCats = null;
        saveNotice = { text: "已保存 ✓" };
        const api = window.__bsb;
        if (api && api.refresh) api.refresh(true); // re-query with the new categories
        renderPanel();
    }

    function renderPanel() {
        const el = ensurePanel();
        const bd = el.querySelector(".bd");
        const api = window.__bsb;
        const segs = (api && api.segments) || [];
        const id = api && api.videoId;
        const cfg = getEffectiveConfig();
        const cats = cfg.categories || {};

        let html = "";
        html += '<div style="opacity:.75;margin-bottom:6px">' +
            (id ? id.bvid + (id.cid ? " · cid " + id.cid : "") : "未识别视频") +
            " · v" + ((api && api.version) || "0.4.6") + "</div>";

        if (!segs.length) {
            html += '<div class="empty">当前视频暂无片段</div>';
        } else {
            segs.forEach(function (seg, i) {
                const meta = catInfo(seg.category);
                const action = ACTION_LABEL[seg.actionType] || seg.actionType;
                html +=
                    '<div class="seg-item" data-i="' + i + '">' +
                    '<span class="swatch" style="background:' + meta.color + '"></span>' +
                    "<span>" + meta.label + " · " + action + "</span>" +
                    '<span class="time">' + fmtTime(seg.start) + "-" + fmtTime(seg.end) + "</span>" +
                    "</div>";
            });
        }

        html += '<div class="cats"><div class="t">类别开关</div>';
        Object.keys(CATEGORY).forEach(function (key) {
            if (key === "exclusive_access") return;
            const meta = CATEGORY[key];
            const on = (pendingCats && key in pendingCats) ? !!pendingCats[key] : cats[key] !== false;
            html +=
                '<label><input type="checkbox" data-cat="' + key + '"' + (on ? " checked" : "") + " />" +
                '<span class="swatch" style="background:' + meta.color + '"></span>' + meta.label + "</label>";
        });
        html += "</div>";
        html += '<div class="foot">' +
            '<button type="button" class="secondary" id="bsb-panel-settings">完整设置</button>' +
            '<button type="button" class="secondary" id="bsb-panel-refresh">重新查询</button>' +
            '<button type="button" class="' + (pendingCats ? "dirty" : "") + '" id="bsb-panel-save">保存更改</button>' +
            "</div>";

        bd.innerHTML = html;

        bd.querySelectorAll(".seg-item").forEach(function (item) {
            item.addEventListener("click", function () {
                const i = Number(item.getAttribute("data-i"));
                const seg = segs[i];
                const v = document.querySelector("video");
                if (!seg || !v) return;
                try { v.currentTime = Math.max(0, seg.start + 0.02); } catch (_) {}
            });
        });

        bd.querySelectorAll("input[data-cat]").forEach(function (input) {
            input.addEventListener("change", function () {
                const key = input.getAttribute("data-cat");
                pendingCats = pendingCats || {};
                pendingCats[key] = !!input.checked;
                saveNotice = null;
                renderPanel(); // refresh the "unsaved" hint and the save button state
            });
        });

        const saveBtn = bd.querySelector("#bsb-panel-save");
        if (saveBtn) {
            saveBtn.addEventListener("click", function () {
                commitPanelChanges();
            });
        }

        const refreshBtn = bd.querySelector("#bsb-panel-refresh");
        if (refreshBtn) {
            refreshBtn.addEventListener("click", function () {
                if (api && api.refresh) api.refresh(true);
                setTimeout(renderPanel, 700);
            });
        }
        updateSaveState();

        const settingsBtn = bd.querySelector("#bsb-panel-settings");
        if (settingsBtn) {
            settingsBtn.addEventListener("click", function () {
                try { localStorage.setItem("bsb_open_settings", String(Date.now())); } catch (_) {}
                closePanel();
            });
        }
    }

    /** Hide the panel AND drop the open flag, otherwise the keep-alive tick reopens it. */
    function closePanel() {
        window.__bsbPanelOpen = false;
        pendingCats = null;
        saveNotice = null;
        const el = panelNode();
        if (el) el.style.display = "none";
        syncButtonState();
    }

    /** A hidden node with a stale "open" flag is closed as far as the user is concerned. */
    function isPanelOpen() {
        const el = panelNode();
        return !!(window.__bsbPanelOpen && el && el.isConnected && el.style.display === "block");
    }

    function syncButtonState() {
        const btn = document.getElementById("bsb-ctrl-btn");
        if (!btn) return;
        // Read the live node, never a cached reference: several builds can be
        // alive for a moment after a payload upgrade, and they must all agree.
        const live = document.getElementById("bsb-panel");
        const open = !!(window.__bsbPanelOpen && live && live.isConnected && live.style.display === "block");
        btn.classList.toggle("bsb-active", open);
    }

    let lastToggleAt = 0;
    function togglePanel() {
        const now = Date.now();
        if (now - lastToggleAt < 250) {
            return;
        }
        lastToggleAt = now;
        const el = ensurePanel();
        if (isPanelOpen()) {
            closePanel();
            return;
        }
        renderPanel();
        try { document.documentElement.appendChild(el); } catch (_) {
            try { document.body.appendChild(el); } catch (__) {}
        }
        mountFloat(el); // clamps size/position to the current viewport
        el.style.display = "block";
        window.__bsbPanelOpen = true;
        syncButtonState();
    }

    /** Stable panel keeper: only remount if open and node vanished */
    function keepPanelAlive() {
        if (!isPanelOpen()) return;
        try {
            let p = document.getElementById("bsb-panel");
            if (!p) {
                p = ensurePanel();
                try { renderPanel(); } catch (_) {}
            }
            if (!p.isConnected) {
                try { document.documentElement.appendChild(p); } catch (_) {
                    try { document.body.appendChild(p); } catch (_) { return; }
                }
            }
            if (p.style.display !== "block") p.style.display = "block";
        } catch (_) {}
    }

    /** Player control-bar button: exactly one instance, left of the quality control. */
    function ensureControlButton() {
        const bar =
            document.querySelector(".bpx-player-control-bottom-right") ||
            document.querySelector(".bpx-player-control-bottom") ||
            document.querySelector(".bpx-player-control-wrap");
        if (!bar) return null;

        let btn = document.getElementById("bsb-ctrl-btn");
        // a leftover button from an older payload has the class but not our id
        document.querySelectorAll(".bsb-ctrl-btn").forEach(function (el) {
            if (el !== btn) { try { el.remove(); } catch (_) {} }
        });

        if (!btn) {
            btn = document.createElement("div");
            btn.id = "bsb-ctrl-btn";
            btn.className = "bsb-ctrl-btn";
            btn.textContent = "BSB";
            btn.title = "空降助手：片段 / 类别";
        } else if (btn.getAttribute("data-bsb-ver") !== VERSION) {
            // The node survives payload upgrades and still carries the previous
            // build's click listener; a clone drops them so a click toggles once.
            const fresh = btn.cloneNode(true);
            btn.replaceWith(fresh);
            btn = fresh;
        }
        if (btn.getAttribute("data-bsb-ver") !== VERSION) btn.setAttribute("data-bsb-ver", VERSION);

        // Clicks are delegated (once per page) to whichever build currently owns
        // window.__bsbUI, so stale listeners can never double-toggle the panel.
        if (!window.__bsbBtnDelegated) {
            window.__bsbBtnDelegated = true;
            document.addEventListener("click", function (e) {
                const t = e.target;
                if (!t || !t.closest || !t.closest("#bsb-ctrl-btn")) return;
                e.preventDefault();
                e.stopPropagation();
                try {
                    if (window.__bsbUI && window.__bsbUI.togglePanel) window.__bsbUI.togglePanel();
                } catch (_) {}
            }, true);
        }

        const quality = bar.querySelector(".bpx-player-ctrl-quality, .squirtle-quality, .bpx-player-ctrl-btn[aria-label*='清晰度']");
        const anchor = quality || null;
        const host = (anchor && anchor.parentElement) || bar;
        const placedRight = anchor ? btn.nextElementSibling === anchor : btn.parentElement === host;
        if (btn.parentElement !== host || !placedRight) {
            // Insert through methods an older payload never monkey-patched: it
            // may have wrapped appendChild/insertBefore to swallow BSB nodes.
            try {
                if (anchor && typeof anchor.before === "function") anchor.before(btn);
                else if (typeof host.prepend === "function") host.prepend(btn);
                else host.insertBefore(btn, anchor);
            } catch (_) {
                try { host.appendChild(btn); } catch (__) {}
            }
        }
        btn.classList.toggle("bsb-active", isPanelOpen());
        return btn;
    }

    function updateButtonVisibility() {
        syncButtonState();
    }

    function purgePermanentBadge() {
        try {
            document.querySelectorAll("#bsb-status-badge").forEach(function (el) {
                try { el.remove(); } catch (_) {}
            });
        } catch (_) {}
    }

    let btnEl = null;

    function syncUi() {
        injectStyles();
        ensureControlButton();
        updateButtonVisibility();
        const api = window.__bsb;
        const segs = (api && api.segments) || [];
        renderPreviewBar(segs);
        if (isPanelOpen()) keepPanelAlive();
        purgePermanentBadge();
    }

    // --- single slow ticker (no stacked RAF) ---
    // Each instance owns its ticker and retires itself once a newer build takes
    // over, so nothing outside this file has to clear the interval: a ticker
    // killed from the outside would silently stop maintaining the button/panel.
    const uiTimer = setInterval(function () {
        try {
            if (window.__bsbUI && window.__bsbUI.version && window.__bsbUI.version !== VERSION) {
                clearInterval(uiTimer);   // never the shared global: it may be the newer build's
                if (window.__bsbUIInterval === uiTimer) window.__bsbUIInterval = null;
                return;
            }
            window.__bsbUItick = (window.__bsbUItick || 0) + 1;
            ensureControlButton();
            updateButtonVisibility();
            ensurePreviewBar();
            keepPanelAlive();
            if (window.__bsb && window.__bsb.__uiDirty) {
                window.__bsb.__uiDirty = false;
                syncUi();
            }
            purgePermanentBadge();
        } catch (_) {}
    }, 400);
    window.__bsbUIInterval = uiTimer;

    window.__bsbUI = {
        refresh: syncUi,
        renderPreviewBar: renderPreviewBar,
        showNotice: showNotice,
        togglePanel: togglePanel,
        state: function () {
            const live = document.getElementById("bsb-panel");
            return {
                version: VERSION,
                panelOpen: isPanelOpen(),
                flag: !!window.__bsbPanelOpen,
                cachedConnected: !!(panelEl && panelEl.isConnected),
                cachedDisplay: panelEl ? panelEl.style.display : null,
                liveDisplay: live ? live.style.display : null,
                buttonCount: document.querySelectorAll(".bsb-ctrl-btn").length,
                ticker: typeof window.__bsbUIInterval,
                tick: window.__bsbUItick || 0
            };
        },
        ensurePanelDom: function () {
            if (!window.__bsbPanelOpen) return;
            keepPanelAlive();
        },
        version: VERSION
    };

    injectStyles();
    ensureControlButton();
    watchPlayer();
    updateButtonVisibility();
    // the player chrome can mount after the payload lands - retry a few times
    setTimeout(repairUi, 600);
    setTimeout(repairUi, 1800);
    setTimeout(repairUi, 4000);
    if (window.__bsb && window.__bsb.segments) renderPreviewBar(window.__bsb.segments);
})();
