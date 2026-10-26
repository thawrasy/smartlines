// The station board on a display hub: the board comes from the hub over a WebSocket (polled if the socket fails), and
// is drawn in the board's languages in turn. Every word comes from the hub's last pull (the platform's labels and city
// names), so the board needs nothing from the internet.
(function () {
  "use strict";
  var code = document.body.getAttribute("data-code");
  var root = document.getElementById("board");
  var data = null, langIndex = 0;

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function langs() { var b = data && data.board; return (b && b.languages && b.languages.length ? b.languages : ["ar", "en"]); }
  function words(lang) { return (data && data.labels && (data.labels[lang] || data.labels.en)) || {}; }
  function city(lang, code, name) { var c = data && data.cities && data.cities[code]; return (c && c[lang]) || name || code || ""; }
  function zone() { var s = data && data.board && data.board.station; return (s && s.time_zone) || "Asia/Damascus"; }
  function hm(lang, iso) {
    try { return new Intl.DateTimeFormat(lang === "ar" ? "ar-SY-u-nu-latn" : "en-GB", { timeZone: zone(), hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(iso)); }
    catch (e) { return iso ? iso.slice(11, 16) : ""; }
  }

  function table(lang, rows, kind) {
    var w = words(lang), t = el("table"), head = el("tr");
    [w.time, kind === "dep" ? w.to : w.from, w.carrier, w.trip, w.bay, w.state].forEach(function (h) { head.appendChild(el("th", null, h || "")); });
    var thead = el("thead"); thead.appendChild(head); t.appendChild(thead);
    var body = el("tbody");
    rows.forEach(function (r) {
      var tr = el("tr", r.status);
      tr.appendChild(el("td", "time", hm(lang, r.at)));
      var place = el("td", null, city(lang, r.city_code, r.city));
      var via = (r.via || []).map(function (v, i) { return city(lang, (r.via_codes || [])[i], v); }).filter(Boolean);
      if (via.length) place.appendChild(el("span", "via", (w.via || "via") + " " + via.join(" · ")));
      tr.appendChild(place);
      tr.appendChild(el("td", null, r.carrier || ""));
      tr.appendChild(el("td", null, r.trip_code || r.trip_no || ""));
      tr.appendChild(el("td", null, r.bay || "—"));
      tr.appendChild(el("td", "status", (w.status && w.status[r.status]) || r.status));
      body.appendChild(tr);
    });
    t.appendChild(body);
    return t;
  }

  function draw() {
    if (!data) return;
    var ls = langs(), lang = ls[langIndex % ls.length], w = words(lang), b = data.board;
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
    root.textContent = "";
    if (!b) { root.appendChild(el("p", "empty", w.screenOff || "")); return; }
    var kind = (b.kind || (data.screen && data.screen.kind) || "COMBINED");
    var header = el("header");
    var left = el("div");
    left.appendChild(el("h1", null, kind === "ARRIVALS" ? w.arrivals : w.departures));
    left.appendChild(el("div", "where", [(b.station && b.station.name) || "", (data.screen && data.screen.label) || ""].filter(Boolean).join(" · ")));
    header.appendChild(left);
    header.appendChild(el("div", "clock", hm(lang, new Date().toISOString())));
    root.appendChild(header);
    var sides = kind === "ARRIVALS" ? [["arr", b.arrivals]] : kind === "DEPARTURES" ? [["dep", b.departures]] : [["dep", b.departures], ["arr", b.arrivals]];
    sides.forEach(function (s) {
      if (sides.length > 1) root.appendChild(el("h2", null, s[0] === "dep" ? w.departures : w.arrivals));
      var rows = s[1] || [];
      root.appendChild(rows.length ? table(lang, rows, s[0]) : el("p", "empty", s[0] === "dep" ? w.noDepartures : w.noArrivals));
    });
    if (data.stale && data.synced_at) {
      root.appendChild(el("div", "stale", (w.offline || "{time}").replace("{time}", hm(lang, new Date(data.synced_at * 1000).toISOString()))));
    }
  }

  function take(d) { data = d; draw(); }
  function poll() {
    fetch("/board/" + encodeURIComponent(code), { cache: "no-store" }).then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d) take(d); }).catch(function () {});
  }
  function connect() {
    var ws;
    try { ws = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws/" + encodeURIComponent(code)); }
    catch (e) { setTimeout(connect, 10000); return; }
    ws.onmessage = function (m) { try { take(JSON.parse(m.data)); } catch (e) { /* ignored */ } };
    ws.onclose = function (e) { if (e.code === 4403) { location.reload(); return; } poll(); setTimeout(connect, 10000); };
  }
  setInterval(function () {
    var seconds = Math.min(60, Math.max(5, (data && data.board && data.board.rotate_seconds) || 10));
    if (Math.floor(Date.now() / 1000) % seconds === 0) { langIndex += 1; draw(); }
  }, 1000);
  setInterval(draw, 30000);
  poll();
  connect();
})();
