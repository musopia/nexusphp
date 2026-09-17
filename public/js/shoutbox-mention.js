/**
 * Homepage shoutbox @ mention autocomplete.
 * Rules: local recent speakers → 1 char local only → ≥2 chars debounce prefix search.
 * Styles injected to avoid stale CSS; panel anchored to input box.
 */
(function () {
  "use strict";

  var DEBOUNCE_MS = 250;
  var MIN_PREFIX = 2;

  var input = document.getElementById("shbox_text");
  if (!input) return;

  // 1) Disable browser autofill / native suggestion popup
  if (input.form) {
    input.form.setAttribute("autocomplete", "off");
  }
  input.setAttribute("autocomplete", "off");
  input.setAttribute("autocorrect", "off");
  input.setAttribute("autocapitalize", "off");
  input.setAttribute("spellcheck", "false");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("role", "combobox");
  // Chrome often ignores autocomplete=off on remembered fields
  input.addEventListener("focus", function () {
    input.setAttribute("readonly", "readonly");
    setTimeout(function () {
      input.removeAttribute("readonly");
    }, 0);
  });

  // ---- critical styles (orange PT skin) ----
  var style = document.createElement("style");
  style.id = "shoutbox-mention-style";
  style.textContent = [
    ".shout-composer{position:relative;}",
    "a.mention{display:inline-block;margin:0 1px;padding:0 5px;border:1px solid #f0b27a;border-radius:3px;background:#fdebd0;color:#b03a10;font-weight:700;font-size:12px;line-height:18px;text-decoration:none;}",
    "a.mention:hover{background:#fad7a0;border-color:#e67e22;color:#8e2f0b;text-decoration:none;}",
    "a.mention.mention-self{background:#d64545;border-color:#a93226;color:#fff;box-shadow:0 0 0 2px rgba(214,69,69,.28);font-weight:800;}",
    "a.mention.mention-self:hover{background:#c0392b;border-color:#922b21;color:#fff;}",
    ".mention-panel{position:absolute;left:0;min-width:260px;max-width:420px;bottom:calc(100% + 8px);background:#fff;border:1px solid #e67e22;border-radius:6px;box-shadow:0 6px 20px rgba(180,90,20,.28);overflow:hidden;z-index:10050;text-align:left;font-family:inherit;}",
    ".mention-panel[hidden]{display:none!important;}",
    ".mention-panel-header{padding:6px 12px;font-size:12px;color:#8b5a2b;background:linear-gradient(90deg,#fff4e6,#ffe8cc);border-bottom:1px solid #f5d0a9;}",
    ".mention-panel-header kbd{display:inline-block;min-width:1.2em;padding:0 3px;margin:0 1px;border:1px solid #d2b48c;border-bottom-width:2px;border-radius:3px;background:#fff;font-size:11px;text-align:center;}",
    ".mention-panel-body{max-height:220px;overflow-y:auto;}",
    ".mention-item{display:flex;align-items:center;justify-content:space-between;gap:12px;width:100%;padding:9px 12px;border:0;border-left:3px solid transparent;border-bottom:1px solid #f7efe6;background:#fff;font:inherit;color:#2b2118;text-align:left;cursor:pointer;}",
    ".mention-item:last-child{border-bottom:0;}",
    ".mention-item:hover{background:#fff8ef;}",
    ".mention-item.active{background:linear-gradient(90deg,#fff1e0,#ffe4c4);border-left-color:#e67e22;}",
    ".mention-item .name{font-weight:700;font-size:13px;color:#5c2e00;}",
    ".mention-item .name mark{background:transparent;color:#e67e22;font-weight:800;}",
    ".mention-item .meta{color:#9a7b5c;font-size:12px;flex:0 0 auto;}",
    ".mention-item.is-self{background:#fff5f5;}",
    ".mention-item.is-self.active{background:linear-gradient(90deg,#fdecea,#f5b7b1);border-left-color:#c0392b;}",
    ".mention-item.is-self .name{color:#c0392b;}",
    ".mention-item.is-self .meta{color:#c0392b;font-weight:700;}",
    ".mention-empty{padding:14px 12px;color:#9a7b5c;font-size:13px;background:#fffdf9;}",
    ".self-tag{display:inline-block;margin-left:6px;padding:1px 6px;font-style:normal;font-size:11px;line-height:16px;color:#fff;background:#e74c3c;border-radius:3px;font-weight:800;letter-spacing:.02em;}"
  ].join("\n");
  if (!document.getElementById("shoutbox-mention-style")) {
    document.head.appendChild(style);
  }

  var wrap = input.closest(".shout-composer") || input.parentNode;
  if (wrap && !wrap.classList.contains("shout-composer")) {
    wrap.classList.add("shout-composer");
  }
  if (wrap) {
    wrap.style.position = "relative";
  }

  var panel = document.createElement("div");
  panel.id = "mention-panel";
  panel.className = "mention-panel";
  panel.hidden = true;
  panel.setAttribute("role", "listbox");
  panel.innerHTML =
    '<div class="mention-panel-header">@ 提及 · <kbd>↑</kbd><kbd>↓</kbd> 选择 · <kbd>Tab</kbd>/<kbd>Enter</kbd> 确认</div>' +
    '<div class="mention-panel-body"></div>';
  var panelBody = panel.querySelector(".mention-panel-body");
  // Anchor to composer row; fallback to input parent
  var anchor = wrap || input.parentNode;
  if (anchor) {
    if (window.getComputedStyle(anchor).position === "static") {
      anchor.style.position = "relative";
    }
    anchor.appendChild(panel);
  }

  var state = {
    open: false,
    items: [],
    active: 0,
    start: -1,
    timer: null,
    reqSeq: 0,
    recent: null,
    recentLoading: false,
    cache: {}
  };

  function post(action, params, cb) {
    var parts = ["action=" + encodeURIComponent(action)];
    if (params) {
      Object.keys(params).forEach(function (k) {
        parts.push(
          "params[" + encodeURIComponent(k) + "]=" + encodeURIComponent(params[k])
        );
      });
    }
    var xhr = new XMLHttpRequest();
    xhr.open("POST", "ajax.php", true);
    xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      if (xhr.status !== 200) {
        cb(null);
        return;
      }
      try {
        var res = JSON.parse(xhr.responseText);
        cb(res && res.ret === 0 ? res.data : null);
      } catch (e) {
        cb(null);
      }
    };
    xhr.send(parts.join("&"));
  }

  function close() {
    state.open = false;
    state.items = [];
    state.active = 0;
    state.start = -1;
    panel.hidden = true;
    panelBody.innerHTML = "";
  }

  function open() {
    state.open = true;
    panel.hidden = false;
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function markPrefix(name, prefix) {
    if (!prefix) return escapeHtml(name);
    if (name.toLowerCase().indexOf(prefix.toLowerCase()) !== 0) {
      return escapeHtml(name);
    }
    return (
      "<mark>" +
      escapeHtml(name.slice(0, prefix.length)) +
      "</mark>" +
      escapeHtml(name.slice(prefix.length))
    );
  }

  function detectToken() {
    var value = input.value;
    var caret = input.selectionStart;
    if (caret == null) return null;
    var before = value.slice(0, caret);
    var m = /(^|[\s（(])@([A-Za-z0-9]{0,20})$/.exec(before);
    if (!m) return null;
    return {
      start: before.length - m[2].length - 1,
      end: caret,
      prefix: m[2]
    };
  }

  function merge(local, remote) {
    var seen = {};
    var out = [];
    function push(u, meta) {
      var id = u.id;
      if (seen[id]) return;
      seen[id] = true;
      out.push({
        id: id,
        username: u.username,
        self: !!u.self,
        meta: u.self ? "你自己" : meta
      });
    }
    (local || []).forEach(function (u) {
      push(u, "最近发言");
    });
    (remote || []).forEach(function (u) {
      push(u, "用户");
    });
    out.sort(function (a, b) {
      if (a.self === b.self) return 0;
      return a.self ? 1 : -1;
    });
    return out.slice(0, 8);
  }

  function filterLocal(prefix) {
    var pool = state.recent || [];
    if (!prefix) return pool;
    var p = prefix.toLowerCase();
    return pool.filter(function (u) {
      return String(u.username || "").toLowerCase().indexOf(p) === 0;
    });
  }

  function setItems(list) {
    state.items = list || [];
    state.active = state.items.length ? 0 : -1;
  }

  function renderPanel(prefix) {
    panelBody.innerHTML = "";
    if (!state.items.length) {
      state.active = -1;
      panelBody.innerHTML =
        '<div class="mention-empty">' +
        (prefix.length >= MIN_PREFIX
          ? "没有匹配的用户"
          : "输入用户名，至少 2 个字符可搜索全站") +
        "</div>";
      open();
      return;
    }
    if (state.active < 0 || state.active >= state.items.length) {
      state.active = 0;
    }
    state.items.forEach(function (item, i) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "mention-item" +
        (i === state.active ? " active" : "") +
        (item.self ? " is-self" : "");
      btn.setAttribute("role", "option");
      btn.setAttribute("aria-selected", i === state.active ? "true" : "false");
      btn.innerHTML =
        '<span class="name">@' +
        markPrefix(item.username, prefix) +
        (item.self ? ' <em class="self-tag">本人</em>' : "") +
        '</span><span class="meta">' +
        escapeHtml(item.self ? "你自己 · Enter/Tab" : item.meta) +
        "</span>";
      btn.addEventListener("mousedown", function (e) {
        e.preventDefault();
        insert(item);
      });
      btn.addEventListener("mousemove", function () {
        if (state.active !== i) {
          state.active = i;
          renderPanel(prefix);
        }
      });
      panelBody.appendChild(btn);
    });
    open();
  }

  function insert(item) {
    var value = input.value;
    var start = state.start;
    var end = input.selectionStart;
    if (start < 0) return;
    var text = "@" + item.username + " ";
    input.value = value.slice(0, start) + text + value.slice(end);
    var caret = start + text.length;
    input.setSelectionRange(caret, caret);
    close();
    input.focus();
  }

  function ensureRecent(cb) {
    if (state.recent) {
      cb(state.recent);
      return;
    }
    if (state.recentLoading) {
      setTimeout(function () {
        ensureRecent(cb);
      }, 50);
      return;
    }
    state.recentLoading = true;
    post("mentionRecentSpeakers", {}, function (data) {
      state.recentLoading = false;
      state.recent = data || [];
      cb(state.recent);
    });
  }

  function searchRemote(prefix) {
    var key = prefix.toLowerCase();
    if (state.cache[key]) {
      setItems(merge(filterLocal(prefix), state.cache[key]));
      renderPanel(prefix);
      return;
    }
    var seq = ++state.reqSeq;
    post("mentionSearch", { q: prefix }, function (data) {
      if (seq !== state.reqSeq) return;
      var list = data || [];
      state.cache[key] = list;
      setItems(merge(filterLocal(prefix), list));
      renderPanel(prefix);
    });
  }

  function schedule(token) {
    clearTimeout(state.timer);
    state.start = token.start;
    var prefix = token.prefix;

    if (prefix.length < MIN_PREFIX) {
      ensureRecent(function () {
        setItems(merge(filterLocal(prefix), []));
        renderPanel(prefix);
      });
      return;
    }

    setItems(merge(filterLocal(prefix), []));
    renderPanel(prefix);
    state.timer = setTimeout(function () {
      searchRemote(prefix);
    }, DEBOUNCE_MS);
  }

  function onInput() {
    var token = detectToken();
    if (!token) {
      if (state.open) close();
      return;
    }
    schedule(token);
  }

  function currentPrefix() {
    var t = detectToken();
    return t ? t.prefix : "";
  }

  function onKeydown(e) {
    if (!state.open) return;
    if (e.key === "ArrowDown" || e.keyCode === 40) {
      e.preventDefault();
      if (!state.items.length) return;
      if (state.active < 0) state.active = 0;
      else state.active = (state.active + 1) % state.items.length;
      renderPanel(currentPrefix());
      return;
    }
    if (e.key === "ArrowUp" || e.keyCode === 38) {
      e.preventDefault();
      if (!state.items.length) return;
      if (state.active < 0) state.active = state.items.length - 1;
      else state.active = (state.active - 1 + state.items.length) % state.items.length;
      renderPanel(currentPrefix());
      return;
    }
    // Tab / Enter: pick current (default first) item
    if (e.key === "Tab" || e.keyCode === 9 || e.key === "Enter" || e.keyCode === 13) {
      if (state.items.length) {
        e.preventDefault();
        var idx = state.active >= 0 ? state.active : 0;
        insert(state.items[idx]);
      } else if (e.key === "Enter" || e.keyCode === 13) {
        e.preventDefault();
        close();
      } else if (e.key === "Tab" || e.keyCode === 9) {
        // empty panel: allow normal focus move
        close();
      }
      return;
    }
    if (e.key === "Escape" || e.keyCode === 27) {
      e.preventDefault();
      close();
    }
  }

  input.addEventListener("input", onInput);
  input.addEventListener("keydown", onKeydown);
  // stop browser from navigating on Tab if panel handled it
  input.addEventListener("keyup", function (e) {
    if (state.open && (e.key === "Tab" || e.keyCode === 9)) {
      e.preventDefault();
    }
  });
  input.addEventListener("blur", function () {
    setTimeout(close, 150);
  });

  var form = input.form;
  if (form) {
    form.addEventListener("submit", function (e) {
      if (state.open && state.items.length) {
        e.preventDefault();
        insert(state.items[state.active]);
      }
    });
  }
})();
