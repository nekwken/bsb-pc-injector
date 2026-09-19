// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// Derived from BilibiliSponsorBlock (GPL-3.0) — see NOTICE.md
//
// bsb-settings.js — inject BSB settings into official PC client settings page
// Mounts a catalog entry on NAV.settings_catalog and a content panel.

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
    const SELF_VERSION = "0.4.8";

    // Re-mounting is idempotent (ensureCatalog reuses #bsb-catalog-item), so a
    // newer build is allowed to take over a page that already runs an older one.
    if (window.__BSB_SETTINGS_LOADED__ && vcmp(window.__BSB_SETTINGS_VERSION__ || "0.0.0", SELF_VERSION) >= 0) return;
    window.__BSB_SETTINGS_LOADED__ = true;
    window.__BSB_SETTINGS_VERSION__ = SELF_VERSION;

    const CAT_LABEL = {
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

    function loadConfig() {
        const base = {
            enabled: true,
            apiBase: "https://www.bsbsb.top",
            originHeader: "electron-bsb-patcher",
            xExtVersion: "0.2.0",
            minVotes: 0,
            showBadge: false,
            showSkipNotice: true,
            categories: {
                sponsor: true, selfpromo: true, exclusive_access: false,
                interaction: true, poi_highlight: false, intro: true, outro: true,
                preview: true, padding: true, filler: true, music_offtopic: true
            },
            actionPreferences: { skip: true, mute: true, full: false, poi: false },
            skipBufferSec: 0.15,
            debug: false
        };
        const host = (window.__BSB_HOST__ && window.__BSB_HOST__.config) || {};
        let saved = {};
        try { saved = JSON.parse(localStorage.getItem("bsb_config") || "{}"); } catch (_) {}
        const cfg = Object.assign({}, base, host, saved);
        cfg.categories = Object.assign({}, base.categories, (host && host.categories) || {}, (saved && saved.categories) || {});
        cfg.actionPreferences = Object.assign({}, base.actionPreferences, (host && host.actionPreferences) || {}, (saved && saved.actionPreferences) || {});
        return cfg;
    }

    function saveConfig(cfg) {
        try {
            localStorage.setItem("bsb_config", JSON.stringify(cfg));
        } catch (e) {}
        // apply live to content engine if present
        try {
            if (window.__bsb && window.__bsb.config) {
                const live = window.__bsb.config;
                Object.assign(live, cfg);
                live.categories = Object.assign({}, cfg.categories);
                live.actionPreferences = Object.assign({}, cfg.actionPreferences);
                if (window.__bsb.refresh) window.__bsb.refresh(true);
            }
        } catch (_) {}
        // also tell any other frames via storage event automatically
        try { localStorage.setItem("bsb_config_t", String(Date.now())); } catch (_) {}
    }

    function ensureStyles() {
        let st = document.getElementById("bsb-settings-style");
        // replace, don't reuse: an older build's rules must not stay in force
        if (st && st.getAttribute("data-bsb-ver") === SELF_VERSION) return;
        if (!st) {
            st = document.createElement("style");
            st.id = "bsb-settings-style";
            (document.head || document.documentElement).appendChild(st);
        }
        st.textContent = `
#bsb-catalog-item.settings_catalog--item{display:flex;align-items:center}
.bsb-settings-section{padding:12px 0 24px;max-width:720px}
.bsb-settings-section h2,.bsb-settings-section h3{margin:0 0 8px;font-weight:600}
.bsb-settings-section .row{display:flex;align-items:center;gap:8px;margin:8px 0;flex-wrap:wrap}
.bsb-settings-section label.ck{display:inline-flex;align-items:center;gap:6px;min-width:140px;cursor:pointer;font-size:13px}
.bsb-settings-section input[type=text],.bsb-settings-section input[type=number]{padding:4px 8px;border:1px solid rgba(128,128,128,.35);border-radius:4px;background:transparent;color:inherit;min-width:240px}
.bsb-settings-section .muted{opacity:.65;font-size:12px}
.bsb-settings-section .swatch{width:10px;height:10px;border-radius:2px;display:inline-block;margin-right:4px}
.bsb-settings-section .btns{display:flex;gap:8px;margin-top:12px}
.bsb-settings-section button{border:0;border-radius:4px;padding:6px 14px;cursor:pointer;font-size:13px;background:#00a1d6;color:#fff}
.bsb-settings-section button.secondary{background:rgba(128,128,128,.25);color:inherit}
.bsb-settings-section .sec{margin-top:16px;padding-top:12px;border-top:1px solid rgba(128,128,128,.2)}
#bsb-settings-panel{display:none}
#bsb-settings-panel.active{display:block}
`;
        st.setAttribute("data-bsb-ver", SELF_VERSION);
    }

    function isSettingsPage() {
        return /#\/page\/settings/i.test(location.hash || "") || /settings/i.test(location.href) &&
            !!document.querySelector(".app_settings, .settings_catalog, .settings_content");
    }

    function findCatalog() {
        return (
            document.querySelector("nav.settings_catalog") ||
            document.querySelector(".settings_catalog")
        );
    }

    function findContentWrap() {
        return (
            document.querySelector(".settings_content--wrapper") ||
            document.querySelector(".settings_content") ||
            document.querySelector(".app_settings--content")
        );
    }

    function hideOfficialSections(on) {
        const wrap = findContentWrap();
        if (!wrap) return;
        const kids = Array.prototype.slice.call(wrap.children);
        kids.forEach(function (el) {
            if (el.id === "bsb-settings-panel") return;
            el.style.display = on ? "none" : "";
        });
    }

    function setActiveCatalog(activeBtn) {
        const cat = findCatalog();
        if (!cat) return;
        cat.querySelectorAll(".settings_catalog--item").forEach(function (b) {
            b.classList.remove("active");
        });
        if (activeBtn) activeBtn.classList.add("active");
    }

    function renderPanel(panel) {
        const cfg = loadConfig();
        const ver = (window.__bsb && window.__bsb.version) || (window.__BSB_HOST__ && window.__BSB_HOST__.version) || "0.2.0";
        let cats = "";
        Object.keys(CAT_LABEL).forEach(function (key) {
            const meta = CAT_LABEL[key];
            const on = cfg.categories && cfg.categories[key] !== false;
            cats +=
                '<label class="ck"><input type="checkbox" data-cat="' + key + '"' + (on ? " checked" : "") + ' />' +
                '<span class="swatch" style="background:' + meta.color + '"></span>' + meta.label + "</label>";
        });
        panel.innerHTML =
            '<div class="bsb-settings-section">' +
            "<h2>空降助手（BilibiliSponsorBlock）</h2>" +
            '<div class="muted">版本 ' + ver + " · 客户端运行时注入 · 数据源 bsbsb.top</div>" +
            '<div class="row"><label class="ck"><input type="checkbox" id="bsb-cfg-enabled"' + (cfg.enabled ? " checked" : "") + " /> 启用片段跳过/静音</label></div>" +
            '<div class="sec"><h3>跳过的类别</h3><div class="row" id="bsb-cfg-cats">' + cats + "</div></div>" +
            '<div class="sec"><h3>动作</h3><div class="row">' +
            '<label class="ck"><input type="checkbox" id="bsb-act-skip"' + (cfg.actionPreferences.skip !== false ? " checked" : "") + " /> 跳过</label>" +
            '<label class="ck"><input type="checkbox" id="bsb-act-mute"' + (cfg.actionPreferences.mute !== false ? " checked" : "") + " /> 静音</label>" +
            '<label class="ck"><input type="checkbox" id="bsb-act-full"' + (cfg.actionPreferences.full ? " checked" : "") + " /> 整段标签</label>" +
            '<label class="ck"><input type="checkbox" id="bsb-act-poi"' + (cfg.actionPreferences.poi ? " checked" : "") + " /> 精彩时刻(poi)</label>" +
            "</div></div>" +
            '<div class="sec"><h3>高级</h3>' +
            '<div class="row"><label>API 地址 <input type="text" id="bsb-cfg-api" value="' + (cfg.apiBase || "") + '" /></label></div>' +
            '<div class="row"><label>跳过缓冲(秒) <input type="number" id="bsb-cfg-buffer" step="0.05" min="0" value="' + (cfg.skipBufferSec != null ? cfg.skipBufferSec : 0.15) + '" /></label></div>' +
            '<div class="row"><label>最低赞数 <input type="number" id="bsb-cfg-votes" min="0" value="' + (cfg.minVotes || 0) + '" /></label></div>' +
            '<div class="row"><label class="ck"><input type="checkbox" id="bsb-cfg-debug"' + (cfg.debug ? " checked" : "") + " /> 调试日志 (console)</label></div>" +
            '<div class="row"><label class="ck"><input type="checkbox" id="bsb-cfg-segbar" checked /> 进度条彩色片段</label></div>' +
            "</div>" +
            '<div class="btns">' +
            '<button type="button" id="bsb-cfg-save">保存设置</button>' +
            '<button type="button" class="secondary" id="bsb-cfg-reset">恢复默认</button>' +
            '<button type="button" class="secondary" id="bsb-cfg-refresh">立即刷新片段</button>' +
            "</div>" +
            '<div class="muted" id="bsb-cfg-msg" style="margin-top:8px"></div>' +
            "</div>";

        const msg = panel.querySelector("#bsb-cfg-msg");
        function say(t) { if (msg) msg.textContent = t || ""; }

        panel.querySelector("#bsb-cfg-save").onclick = function () {
            const next = loadConfig();
            next.enabled = panel.querySelector("#bsb-cfg-enabled").checked;
            next.categories = next.categories || {};
            panel.querySelectorAll("#bsb-cfg-cats input[data-cat]").forEach(function (input) {
                next.categories[input.getAttribute("data-cat")] = !!input.checked;
            });
            next.actionPreferences = {
                skip: panel.querySelector("#bsb-act-skip").checked,
                mute: panel.querySelector("#bsb-act-mute").checked,
                full: panel.querySelector("#bsb-act-full").checked,
                poi: panel.querySelector("#bsb-act-poi").checked
            };
            next.apiBase = panel.querySelector("#bsb-cfg-api").value.trim() || next.apiBase;
            next.skipBufferSec = Number(panel.querySelector("#bsb-cfg-buffer").value) || 0.15;
            next.minVotes = Number(panel.querySelector("#bsb-cfg-votes").value) || 0;
            next.debug = panel.querySelector("#bsb-cfg-debug").checked;
            next.showBadge = false;
            next.showSkipNotice = true;
            saveConfig(next);
            say("已保存 · " + new Date().toLocaleTimeString());
        };
        panel.querySelector("#bsb-cfg-reset").onclick = function () {
            try { localStorage.removeItem("bsb_config"); } catch (_) {}
            renderPanel(panel);
            say("已恢复默认（请再点保存写入运行配置）");
        };
        panel.querySelector("#bsb-cfg-refresh").onclick = function () {
            if (window.__bsb && window.__bsb.refresh) {
                window.__bsb.refresh(true);
                say("已请求刷新片段");
            } else {
                say("请在播放页查看效果（当前页无播放引擎）");
            }
        };
    }

    function ensurePanel() {
        const wrap = findContentWrap();
        if (!wrap) return null;
        let panel = document.getElementById("bsb-settings-panel");
        if (!panel) {
            panel = document.createElement("div");
            panel.id = "bsb-settings-panel";
            wrap.appendChild(panel);
        }
        return panel;
    }

    function showBsbSettings(btn) {
        ensureStyles();
        const panel = ensurePanel();
        if (!panel) return;
        setActiveCatalog(btn || document.getElementById("bsb-catalog-item"));
        hideOfficialSections(true);
        panel.classList.add("active");
        renderPanel(panel);
    }

    function showOfficialSettings(restoreBtn) {
        hideOfficialSections(false);
        const panel = document.getElementById("bsb-settings-panel");
        if (panel) panel.classList.remove("active");
        if (restoreBtn) setActiveCatalog(restoreBtn);
    }

    function ensureCatalog() {
        const cat = findCatalog();
        if (!cat) return null;
        let btn = document.getElementById("bsb-catalog-item");
        if (!btn) {
            btn = document.createElement("button");
            btn.id = "bsb-catalog-item";
            btn.type = "button";
            btn.className = "settings_catalog--item text_ellipsis";
            btn.textContent = "空降助手";
            btn.title = "BilibiliSponsorBlock 设置";
            cat.appendChild(btn);
        }
        btn.onclick = function (e) {
            e.preventDefault();
            e.stopPropagation();
            showBsbSettings(btn);
        };
        return btn;
    }

    // intercept official catalog clicks to restore official panels
    function hookOfficialCatalog() {
        const cat = findCatalog();
        if (!cat || cat.__bsbHooked) return;
        cat.__bsbHooked = true;
        cat.addEventListener("click", function (e) {
            const item = e.target && e.target.closest && e.target.closest(".settings_catalog--item");
            if (!item) return;
            if (item.id === "bsb-catalog-item") return;
            setTimeout(function () { showOfficialSettings(item); }, 0);
        }, true);
    }

    let autoOpened = false;   // auto-show our section at most once per page load

    function mount() {
        // only remove permanent badge; never remove player floating panel/notice
        try {
            const badge = document.getElementById("bsb-status-badge");
            if (badge) badge.remove();
        } catch (_) {}
        if (!isSettingsPage() && !document.querySelector(".settings_catalog")) return;
        ensureStyles();
        const btn = ensureCatalog();
        if (!btn) return;
        hookOfficialCatalog();
        const wantOpen = (location.hash && /bsb|sponsor/i.test(location.hash)) ||
            /bsb_open_settings/.test(String(localStorage.getItem("bsb_open_settings") || ""));
        // Show our section once per page load when the settings page is open, so
        // the user finds it without hunting for the catalog entry. After that we
        // stay out of the way - clicking an official item keeps it hidden.
        if (wantOpen || (!autoOpened && isSettingsPage())) {
            try { localStorage.removeItem("bsb_open_settings"); } catch (_) {}
            autoOpened = true;
            showBsbSettings(btn);
        }
    }

    // Self-retiring ticker: stops once a newer build owns the page.
    // It must clear its OWN id - the shared global may already point at the
    // newer instance's timer, and clearing that would leave the page unmanaged.
    const settingsTimer = setInterval(function () {
        try {
            if (window.__bsbSettings && window.__bsbSettings.version && window.__bsbSettings.version !== SELF_VERSION) {
                clearInterval(settingsTimer);
                if (window.__bsbSettingsInterval === settingsTimer) window.__bsbSettingsInterval = null;
                return;
            }
            mount();
        } catch (_) {}
    }, 800);
    window.__bsbSettingsInterval = settingsTimer;
    mount();
    // if already on settings, show BSB section by default after inject
    setTimeout(function () {
        if (isSettingsPage() || document.querySelector(".settings_catalog")) {
            const btn = ensureCatalog();
            if (btn && !document.querySelector("#bsb-settings-panel.active")) {
                // only auto-open if no other catalog item was clicked after inject
                // keep auto-open for first inject so user sees settings attached
                showBsbSettings(btn);
            }
        }
    }, 300);

    window.__bsbSettings = {
        open: function () { mount(); showBsbSettings(); },
        loadConfig: loadConfig,
        saveConfig: saveConfig,
        version: SELF_VERSION
    };
})();
