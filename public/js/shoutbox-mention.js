/**
 * Homepage shoutbox @ mention autocomplete.
 * Rules: local recent speakers → 1 char local only → ≥2 chars debounce prefix search.
 */
(function () {
  "use strict";

  var DEBOUNCE_MS = 250;
  var MIN_PREFIX = 2;

  var input = document.getElementById("shbox_text");
  if (!input) return;

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
  if (wrap) wrap.appendChild(panel);

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
    // Match project convention: jQuery-style nested params (params[q]=...)
    var parts = ["action=" + encodeURIComponent(action)];
    if (params) {
      Object.keys(params).forEach(function (k) {
        parts.push(
          "params[" + encodeURIComponent(k) + "]=" + encodeURIComponent(params[k])
        );
      }
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
    panel.innerHTML = "";
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
      push(u, "前缀匹配");
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

  function renderPanel(prefix) {
    if (!state.items.length) {
      panel.innerHTML =
        '<div class="mention-empty">' +
        (prefix.length >= MIN_PREFIX
          ? "没有匹配的用户"
          : "输入用户名，至少 2 个字符可搜索") +
        "</div>";
      open();
      return;
    }
    panel.innerHTML = "";
    state.items.forEach(function (item, i) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "mention-item" +
        (i === state.active ? " active" : "") +
        (item.self ? " is-self" : "");
      btn.innerHTML =
        '<span class="name">' +
        markPrefix(item.username, prefix) +
        (item.self ? ' <em class="self-tag">本人</em>' : "") +
        '</span><span class="meta">' +
        escapeHtml(item.meta) +
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
      panel.appendChild(btn);
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
      state.items = merge(filterLocal(prefix), state.cache[key]);
      renderPanel(prefix);
      return;
    }
    var seq = ++state.reqSeq;
    post("mentionSearch", { q: prefix }, function (data) {
      if (seq !== state.reqSeq) return;
      var list = data || [];
      state.cache[key] = list;
      state.items = merge(filterLocal(prefix), list);
      renderPanel(prefix);
    });
  }

  function schedule(token) {
    clearTimeout(state.timer);
    state.start = token.start;
    var prefix = token.prefix;

    if (prefix.length < MIN_PREFIX) {
      ensureRecent(function () {
        state.items = merge(filterLocal(prefix), []);
        renderPanel(prefix);
      });
      return;
    }

    state.items = merge(filterLocal(prefix), []);
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
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (!state.items.length) return;
      state.active = (state.active + 1) % state.items.length;
      renderPanel(currentPrefix());
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      if (!state.items.length) return;
      state.active =
        (state.active - 1 + state.items.length) % state.items.length;
      renderPanel(currentPrefix());
      return;
    }
    if (e.key === "Enter" || e.key === "Tab") {
      if (state.items.length) {
        e.preventDefault();
        insert(state.items[state.active]);
      } else if (e.key === "Enter") {
        e.preventDefault();
        close();
      }
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      close();
    }
  }

  input.addEventListener("input", onInput);
  input.addEventListener("keydown", onKeydown);
  input.addEventListener("blur", function () {
    setTimeout(close, 120);
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
