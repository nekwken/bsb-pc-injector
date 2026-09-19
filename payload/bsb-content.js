// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// Derived from BilibiliSponsorBlock (GPL-3.0) — see NOTICE.md
//
// bsb-content.js — official Bilibili PC client (bilipc) runtime inject
// Parse bvid/cid from player.html query string (window.__INITIAL_STATE__ is absent)
// Derived from hanydd/BilibiliSponsorBlock protocol (GPL-3.0)

(function () {
    "use strict";

    function vcmp(a, b) {
        const pa = String(a || "0").split(".").map(Number);
        const pb = String(b || "0").split(".").map(Number);
        for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
            const d = (pa[i] || 0) - (pb[i] || 0);
            if (d) return d > 0 ? 1 : -1;
        }
        return 0;
    }
    const selfVersion = (window.__BSB_HOST__ && window.__BSB_HOST__.version) || "0.0.0";

    // A page keeps whatever build reached it first; take over when ours is newer.
    if (window.__BSB_CONTENT_LOADED__ && vcmp(window.__BSB_CONTENT_VERSION__ || "0.0.0", selfVersion) >= 0) {
        try { window.__bsb && window.__bsb.refresh && window.__bsb.refresh(); } catch (_) {}
        return;
    }
    try { window.__bsb && window.__bsb.stop && window.__bsb.stop(); } catch (_) {}
    window.__BSB_CONTENT_LOADED__ = true;
    window.__BSB_CONTENT_VERSION__ = selfVersion;

    const HOST = window.__BSB_HOST__ || {};
    const DEFAULTS = {
        enabled: true,
        apiBase: "https://www.bsbsb.top",
        originHeader: "electron-bsb-patcher",
        xExtVersion: "0.2.1",
        minVotes: 0,
        showBadge: false,
        showSkipNotice: true,
        categories: {
            sponsor: true,
            selfpromo: true,
            exclusive_access: false,
            interaction: true,
            poi_highlight: false,
            intro: true,
            outro: true,
            preview: true,
            padding: true,
            filler: true,
            music_offtopic: true
        },
        actionPreferences: { skip: true, mute: true, full: false, poi: false },
        skipBufferSec: 0.15,
        debug: false
    };

    function readLocalStorageConfig() {
        try {
            return JSON.parse(localStorage.getItem("bsb_config") || "{}") || {};
        } catch (_) {
            return {};
        }
    }

    function buildConfig() {
        const ls = readLocalStorageConfig();
        const cfg = Object.assign({}, DEFAULTS, HOST.config || {}, ls);
        cfg.categories = Object.assign({}, DEFAULTS.categories, (HOST.config && HOST.config.categories) || {}, ls.categories || {});
        cfg.actionPreferences = Object.assign({}, DEFAULTS.actionPreferences, (HOST.config && HOST.config.actionPreferences) || {}, ls.actionPreferences || {});
        if (ls.showBadge === undefined) cfg.showBadge = false;
        if (ls.showSkipNotice === undefined) cfg.showSkipNotice = true;
        return cfg;
    }

    let cfg = buildConfig();
    const version = HOST.version || "0.0.0";

    try {
        window.addEventListener("storage", function (e) {
            if (!e || (e.key !== "bsb_config" && e.key !== "bsb_config_t")) return;
            cfg = buildConfig();
            debug("config reloaded from storage");
            ensureLookup(true);
        });
    } catch (_) {}

    function debug() {
        if (!cfg.debug) return;
        try { console.log.apply(console, ["[bsb]"].concat([].slice.call(arguments))); } catch (_) {}
    }

    debug("content loaded", { href: location.href, version, apiBase: cfg.apiBase, injector: HOST.injector });

    // Sweep away leftovers from an older payload. Our own button (id
    // bsb-ctrl-btn) is left alone - an older build's button has the class only.
    (function blockBsbButtonInsert() {
        // An older build may have wrapped these with a stricter filter; undo it
        // first so this build's rules are the only ones in force.
        function restorePatched() {
            try {
                const o = window.__bsbOrigProto;
                if (!o) return;
                if (o.appendChild) Element.prototype.appendChild = o.appendChild;
                if (o.insertBefore) Element.prototype.insertBefore = o.insertBefore;
                if (o.append) Element.prototype.append = o.append;
                if (o.replaceWith) Element.prototype.replaceWith = o.replaceWith;
                if (o.innerHTML) Object.defineProperty(Element.prototype, "innerHTML", o.innerHTML);
                delete window.__bsbOrigProto;
            } catch (_) {}
        }
        restorePatched();
        if (window.__bsbButtonBlock === "v2") return;
        window.__bsbButtonBlock = "v2";

        function isForeignBsbBtn(node) {
            if (!node || node.nodeType !== 1) return false;
            if (node.id === "bsb-ctrl-btn") return false;
            const cls = (node.className || "").toString();
            return cls.indexOf("bsb-ctrl-btn") >= 0;
        }
        function patch(proto, name) {
            const orig = proto[name];
            if (!orig) return;
            proto[name] = function (child) {
                try {
                    if (isForeignBsbBtn(child)) {
                        try { child.remove(); } catch (_) {}
                        return child;
                    }
                } catch (_) {}
                return orig.apply(this, arguments);
            };
        }
        try {
            // remember the untouched functions so a later build can restore them
            window.__bsbOrigProto = {
                appendChild: Element.prototype.appendChild,
                insertBefore: Element.prototype.insertBefore,
                append: Element.prototype.append,
                replaceWith: Element.prototype.replaceWith,
                innerHTML: Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML")
            };
            patch(Element.prototype, "appendChild");
            patch(Element.prototype, "insertBefore");
            patch(Element.prototype, "append");
            if (Element.prototype.replaceWith) {
                const origRep = Element.prototype.replaceWith;
                Element.prototype.replaceWith = function () {
                    try {
                        const args = Array.prototype.slice.call(arguments).filter(function (n) { return !isForeignBsbBtn(n); });
                        return origRep.apply(this, args);
                    } catch (_) {
                        return origRep.apply(this, arguments);
                    }
                };
            }
            // strip a foreign button from innerHTML assignments (old UI rebuilt the bar)
            const idesc = Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML");
            if (idesc && idesc.set) {
                Object.defineProperty(Element.prototype, "innerHTML", {
                    configurable: true,
                    enumerable: idesc.enumerable,
                    get: function () { return idesc.get.call(this); },
                    set: function (v) {
                        if (typeof v === "string" && /bsb-ctrl-btn/i.test(v) && v.indexOf('id="bsb-ctrl-btn"') < 0) {
                            v = v
                                .replace(/<div[^>]*class=["'][^"']*bsb-ctrl-btn[^"']*["'][^>]*>[\s\S]*?<\/div>/gi, "")
                                .replace(/<[^>]*bsb-ctrl-btn[^>]*>[^<]*<\/[^>]+>/gi, "")
                                .replace(/<[^>]*bsb-ctrl-btn[^>]*\/?>/gi, "");
                        }
                        return idesc.set.call(this, v);
                    }
                });
            }
        } catch (_) {}
    })();

    function destroyResidentUi() {
        try {
            document.querySelectorAll(".bsb-ctrl-btn:not(#bsb-ctrl-btn), #bsb-status-badge").forEach(function (el) {
                try { el.remove(); } catch (_) {
                    try { el.parentNode && el.parentNode.removeChild(el); } catch (__) {}
                }
            });
        } catch (_) {}
    }
    destroyResidentUi();
    try {
        if (window.__bsbKillMo) { try { window.__bsbKillMo.disconnect(); } catch (_) {} }
        const killMo = new MutationObserver(function () { destroyResidentUi(); });
        killMo.observe(document.documentElement || document, { childList: true, subtree: true });
        window.__bsbKillMo = killMo;
    } catch (_) {}
    if (window.__bsbKillTimer) { try { clearInterval(window.__bsbKillTimer); } catch (_) {} }
    window.__bsbKillTimer = setInterval(destroyResidentUi, 200);

    try {
        document.querySelectorAll("#bsb-status-badge").forEach(function (el) {
            try { el.remove(); } catch (_) {}
        });
    } catch (_) {}

    let video = null;
    let videoKey = "";
    let segments = [];
    let skipFlags = [];
    let mutedByUs = false;
    let pollingTimer = null;
    let lastLookupAt = 0;
    let badgeEl = null;
    let lastSkipCount = 0;

    function parseQuery() {
        try {
            const u = new URL(location.href);
            return {
                bvid: u.searchParams.get("bvid") || u.searchParams.get("BV") || null,
                cid: u.searchParams.get("cid") || null,
                aid: u.searchParams.get("aid") || null,
                page: u.searchParams.get("page") || "1"
            };
        } catch (_) {
            return { bvid: null, cid: null, aid: null, page: "1" };
        }
    }

    function parseBvAnywhere(url) {
        const m = String(url || location.href).match(/BV[0-9A-Za-z]+/);
        return m ? m[0] : null;
    }

    function readInitialState() {
        try {
            const s = window.__INITIAL_STATE__;
            if (s && (s.bvid || s.aid) && s.cid) {
                return { bvid: s.bvid || null, aid: s.aid || null, cid: String(s.cid) };
            }
        } catch (_) {}
        try {
            const p = window.player && window.player.getManifest && window.player.getManifest();
            if (p && p.cid && (p.bvid || p.aid)) {
                return { bvid: p.bvid || null, aid: p.aid || null, cid: String(p.cid) };
            }
        } catch (_) {}
        return null;
    }

    /** Official PC client: bilipc player.html?bvid=&cid=&aid= */
    function resolveVideoId() {
        const q = parseQuery();
        const fromState = readInitialState();
        const bvid = (fromState && fromState.bvid) || q.bvid || parseBvAnywhere();
        const cid = (fromState && fromState.cid) || q.cid || null;
        const aid = (fromState && fromState.aid) || q.aid || null;
        if (!bvid) return null;
        return {
            bvid: bvid,
            cid: cid ? String(cid) : null,
            aid: aid ? String(aid) : null,
            key: bvid + "+" + (cid || "")
        };
    }

    function findVideoElement() {
        const candidates = document.querySelectorAll("video");
        for (const v of candidates) {
            if (v.readyState > 0 || (v.duration && isFinite(v.duration) && v.duration > 0)) return v;
        }
        return candidates[0] || null;
    }

    function enabledCategories() {
        return Object.keys(cfg.categories || {}).filter((k) => cfg.categories[k]);
    }

    function actionAllowed(action) {
        const p = cfg.actionPreferences || {};
        if (action === "skip") return p.skip !== false;
        if (action === "mute") return p.mute !== false;
        if (action === "full") return !!p.full;
        if (action === "poi") return !!p.poi;
        return action === "skip";
    }

    function ensureBadge() {
        if (!cfg.showBadge) return null;
        // dedupe leftover badges from re-inject
        try {
            const all = document.querySelectorAll("#bsb-status-badge");
            for (let i = 1; i < all.length; i++) all[i].remove();
        } catch (_) {}
        if (badgeEl && badgeEl.isConnected) return badgeEl;
        badgeEl = document.getElementById("bsb-status-badge");
        if (badgeEl) return badgeEl;
        try {
            badgeEl = document.createElement("div");
            badgeEl.id = "bsb-status-badge";
            badgeEl.style.cssText = [
                "position:fixed",
                "right:12px",
                "bottom:70px",
                "z-index:999999",
                "padding:6px 10px",
                "border-radius:6px",
                "font:12px/1.4 system-ui,sans-serif",
                "color:#fff",
                "background:rgba(0,0,0,0.65)",
                "border:1px solid rgba(255,255,255,0.15)",
                "pointer-events:none",
                "max-width:240px"
            ].join(";");
            badgeEl.textContent = "BSB v" + version + " …";
            (document.body || document.documentElement).appendChild(badgeEl);
        } catch (_) {
            badgeEl = null;
        }
        return badgeEl;
    }

    function setBadge(text, color) {
        if (!cfg.showBadge) return;
        // floating badge removed by default; hook kept for debug configs
        try {
            let el = document.getElementById("bsb-status-badge");
            if (!el) return;
            el.textContent = text;
            if (color) el.style.background = color;
        } catch (_) {}
    }

    async function fetchSegments(bvid, cid) {
        const base = String(cfg.apiBase || "").replace(/\/+$/, "");
        const cats = enabledCategories();
        const url = new URL(base + "/api/skipSegments");
        url.searchParams.set("videoID", bvid);
        if (cid) url.searchParams.set("cid", cid);
        try { url.searchParams.set("categories", JSON.stringify(cats)); } catch (_) {}

        const headers = {
            "origin": cfg.originHeader || "electron-bsb-patcher",
            "x-ext-version": cfg.xExtVersion || "0.1.1"
        };

        debug("fetch", url.toString());
        const res = await fetch(url.toString(), { method: "GET", headers: headers });
        debug("fetch status", res.status);
        if (res.status === 404) return [];
        if (!res.ok) return null;
        const data = await res.json();
        return normalizeSegments(data, cid);
    }

    function normalizeSegments(data, cid) {
        if (!data) return [];
        let list = [];
        if (Array.isArray(data)) {
            if (data.length && data[0] && Array.isArray(data[0].segments)) {
                for (const item of data) list = list.concat(item.segments || []);
            } else {
                list = data;
            }
        }
        return list
            .filter((s) => s && Array.isArray(s.segment) && s.segment.length >= 2)
            .map((s) => ({
                start: Number(s.segment[0]),
                end: Number(s.segment[1]),
                category: s.category || "sponsor",
                actionType: s.actionType || "skip",
                uuid: s.UUID || s.uuid || "",
                votes: typeof s.votes === "number" ? s.votes : 0,
                cid: s.cid ? String(s.cid) : null
            }))
            .filter((s) => isFinite(s.start) && isFinite(s.end) && s.end > s.start)
            .filter((s) => (s.votes || 0) >= (cfg.minVotes || 0))
            .filter((s) => (cfg.categories || {})[s.category] !== false)
            .filter((s) => actionAllowed(s.actionType))
            .filter((s) => {
                if (!s.cid || !cid) return true;
                return String(s.cid) === String(cid);
            })
            .sort((a, b) => a.start - b.start);
    }

    async function maybeReportView(seg) {
        if (!seg || !seg.uuid) return;
        const base = String(cfg.apiBase || "").replace(/\/+$/, "");
        try {
            fetch(base + "/api/viewedVideoSponsorTime", {
                method: "POST",
                headers: {
                    "content-type": "application/json",
                    "origin": cfg.originHeader || "electron-bsb-patcher",
                    "x-ext-version": cfg.xExtVersion || "0.1.1"
                },
                body: JSON.stringify({ UUID: seg.uuid })
            }).catch(() => {});
        } catch (_) {}
    }

    function resetSkipFlags() {
        skipFlags = segments.map(() => false);
    }

    function activeSegmentAt(t) {
        const buf = cfg.skipBufferSec || 0.15;
        for (let i = 0; i < segments.length; i++) {
            const s = segments[i];
            if (t + buf >= s.start && t < s.end) return { seg: s, index: i };
        }
        return null;
    }

    function endMuteIfNeeded(t) {
        if (!mutedByUs || !video) return;
        const anyMuteActive = segments.some((s) => s.actionType === "mute" && t >= s.start && t < s.end);
        if (!anyMuteActive) {
            try { video.muted = false; } catch (_) {}
            mutedByUs = false;
        }
    }

    function tick() {
        if (!cfg.enabled || !video) return;
        let t = video.currentTime;
        if (!isFinite(t)) return;

        const hit = activeSegmentAt(t);
        endMuteIfNeeded(t);
        if (!hit) return;

        const { seg, index } = hit;
        if (skipFlags[index]) {
            if (seg.actionType === "mute" && !video.muted) {
                try { video.muted = true; mutedByUs = true; } catch (_) {}
            }
            return;
        }

        const action = seg.actionType || "skip";
        if (action === "skip" || action === "full") {
            const target = Math.min(seg.end + 0.05, (video.duration || seg.end) - 0.05);
            debug("SKIP", seg.category, t.toFixed(2), "->", target.toFixed(2));
            try { video.currentTime = target; } catch (_) {}
            skipFlags[index] = true;
            lastSkipCount += 1;
            if (cfg.showSkipNotice && window.__bsbUI && window.__bsbUI.showNotice) {
                window.__bsbUI.showNotice({
                    category: seg.category,
                    actionType: action,
                    start: seg.start,
                    end: seg.end,
                    votes: seg.votes,
                    uuid: seg.uuid
                });
            }
            maybeReportView(seg);
        } else if (action === "mute") {
            debug("MUTE", seg.category, t.toFixed(2));
            try { video.muted = true; mutedByUs = true; } catch (_) {}
            skipFlags[index] = true;
            if (cfg.showSkipNotice && window.__bsbUI && window.__bsbUI.showNotice) {
                window.__bsbUI.showNotice({
                    category: seg.category,
                    actionType: action,
                    start: seg.start,
                    end: seg.end,
                    votes: seg.votes,
                    uuid: seg.uuid
                });
            }
            maybeReportView(seg);
        } else {
            skipFlags[index] = true;
        }
    }

    function attachVideo(v) {
        if (!v || v === video) return;
        video = v;
        debug("video attached", { duration: v.duration, ready: v.readyState });
        try {
            v.addEventListener("timeupdate", tick);
            v.addEventListener("seeked", tick);
        } catch (_) {}
        tick();
    }

    function ensureLookup(force) {
        const id = resolveVideoId();
        if (!id) {
            setBadge("BSB v" + version + " · 未解析到 BV", "rgba(120,0,0,0.75)");
            return;
        }
        const key = id.key;
        if (!force && key === videoKey && segments.length) return;

        const now = Date.now();
        if (!force && now - lastLookupAt < 1200) return;
        lastLookupAt = now;

        if (key !== videoKey) {
            videoKey = key;
            segments = [];
            resetSkipFlags();
            lastSkipCount = 0;
        }

        debug("lookup", id.bvid, id.cid);
        setBadge("BSB v" + version + " · 查询 " + id.bvid, "rgba(0,0,0,0.55)");

        fetchSegments(id.bvid, id.cid).then((list) => {
            segments = list || [];
            resetSkipFlags();
            debug("segments", segments.length, segments);
            if (segments.length) {
                setBadge("BSB · " + id.bvid + " · " + segments.length + " 段", "rgba(0,80,140,0.85)");
            } else {
                setBadge("BSB · " + id.bvid + " · 无片段", "rgba(70,70,70,0.8)");
            }
            if (window.__bsbUI) {
                try {
                    window.__bsbUI.renderPreviewBar(segments);
                    window.__bsbUI.refresh && window.__bsbUI.refresh();
                } catch (_) {}
            }
            if (window.__bsb) window.__bsb.__uiDirty = true;
            tick();
        }).catch((e) => {
            debug("lookup fail", e);
            setBadge("BSB · 查询失败", "rgba(120,0,0,0.75)");
        });
    }

    function startPolling() {
        if (pollingTimer) return;
        pollingTimer = setInterval(function () {
            if (!video) {
                const v = findVideoElement();
                if (v) attachVideo(v);
            }
            ensureLookup(false);
        }, 1000);
    }

    let lastHref = location.href;
    function onMaybeNavigate() {
        if (location.href !== lastHref) {
            lastHref = location.href;
            videoKey = "";
            segments = [];
            skipFlags = [];
            lastSkipCount = 0;
            debug("navigate", lastHref);
        }
        ensureLookup(true);
        const v = findVideoElement();
        if (v) attachVideo(v);
    }

    try {
        window.addEventListener("hashchange", onMaybeNavigate);
        window.addEventListener("popstate", onMaybeNavigate);
        const wrap = function (type) {
            const orig = history[type];
            return function () {
                const r = orig.apply(this, arguments);
                setTimeout(onMaybeNavigate, 0);
                return r;
            };
        };
        history.pushState = wrap("pushState");
        history.replaceState = wrap("replaceState");
    } catch (_) {}

    try {
        const mo = new MutationObserver(function () {
            if (!video) {
                const v = findVideoElement();
                if (v) attachVideo(v);
            }
        });
        mo.observe(document.documentElement || document, { childList: true, subtree: true });
        window.__bsbWatchMo = mo;
    } catch (_) {}

    onMaybeNavigate();
    startPolling();

    window.__bsb = {
        get config() { return cfg; },
        get segments() { return segments; },
        get video() { return video; },
        get videoId() { return resolveVideoId(); },
        refresh: function (force) { ensureLookup(force !== false); },
        /** release timers/observers so a newer build can take over this page */
        stop: function () {
            try { if (pollingTimer) clearInterval(pollingTimer); } catch (_) {}
            pollingTimer = null;
            try { if (window.__bsbKillTimer) clearInterval(window.__bsbKillTimer); } catch (_) {}
            try { window.__bsbKillTimer = null; } catch (_) {}
            try { window.__bsbKillMo && window.__bsbKillMo.disconnect(); } catch (_) {}
            try { window.__bsbWatchMo && window.__bsbWatchMo.disconnect(); } catch (_) {}
            try { window.__BSB_CONTENT_LOADED__ = false; } catch (_) {}
            debug("stopped (superseded)");
        },
        version: version,
        __uiDirty: false
    };

    debug("ready", version, "id", resolveVideoId());
    // UI layer may load after content
    setTimeout(function () {
        if (window.__bsbUI) {
            try {
                window.__bsbUI.renderPreviewBar(segments);
                window.__bsbUI.refresh && window.__bsbUI.refresh();
            } catch (_) {}
        }
    }, 300);
})();
