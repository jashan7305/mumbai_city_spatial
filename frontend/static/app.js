// ---------- helpers ----------
function el(tag, attrs = {}, text) {
  const node = document.createElement(tag);
  Object.entries(attrs).forEach(([k, v]) => node.setAttribute(k, v));
  if (text !== undefined) node.textContent = text;
  return node;
}

function isPlan(result) {
  return result.columns.length === 1 && result.columns[0] === "QUERY PLAN";
}

// Render a result set into `target`: a table, or a <pre> for EXPLAIN plans.
function renderResult(target, result) {
  if (result.caption) target.append(el("h3", {}, result.caption));
  if (isPlan(result)) {
    target.append(el("pre", { class: "plan" }, result.rows.map((r) => r[0]).join("\n")));
    return;
  }
  const table = el("table");
  const head = el("tr");
  result.columns.forEach((c) => head.append(el("th", {}, c)));
  table.append(head);
  result.rows.forEach((row) => {
    const tr = el("tr");
    row.forEach((v) => {
      if (v === null) {
        tr.append(el("td", { class: "null" }, "NULL"));
      } else {
        tr.append(el("td", { class: /^-?\d+(\.\d+)?$/.test(v) ? "num" : "" }, v));
      }
    });
    table.append(tr);
  });
  const wrap = el("div", { class: "table-wrap" });
  wrap.append(table);
  target.append(wrap);
}

async function postJSON(url, body) {
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { ok: response.ok, data: await response.json() };
}

// ---------- A. predefined project queries ----------
const querySelect = document.getElementById("query");
const paramsForm = document.getElementById("params");
const runButton = document.getElementById("run");
const statusLine = document.getElementById("status");
const resultsDiv = document.getElementById("results");

function showQuery() {
  const q = CATALOG[querySelect.value];
  // Explanatory comments from the SQL file (empty when the block has none).
  document.getElementById("description").textContent = q.description;
  document.getElementById("sql").textContent = q.sql;

  paramsForm.replaceChildren();
  Object.entries(q.defaults).forEach(([name, value]) => {
    const box = el("div");
    box.append(el("label", { for: "p-" + name }, LABELS[name]));
    let input;
    if (CHOICES[name]) {
      input = el("select", { id: "p-" + name, name });
      CHOICES[name].forEach((c) => input.append(el("option", { value: c }, c)));
    } else {
      input = el("input", { id: "p-" + name, name, type: "text", inputmode: "decimal" });
    }
    input.value = value;
    box.append(input);
    paramsForm.append(box);
  });
  if (Object.keys(q.defaults).length) {
    paramsForm.append(el("p", { class: "hint" },
      "Defaults are the values written in the query file (and in its title)."));
  }
  resultsDiv.replaceChildren();
  statusLine.textContent = "";
}

async function runQuery() {
  const id = querySelect.value;
  const params = Object.fromEntries(new FormData(paramsForm));
  runButton.disabled = true;
  statusLine.textContent = "Running…";
  resultsDiv.replaceChildren();
  try {
    const { ok, data } = await postJSON("/run", { id, params });
    if (!ok) {
      statusLine.textContent = "";
      resultsDiv.append(el("p", { class: "error" }, data.error || "Request failed."));
      return;
    }
    const used = Object.entries(data.params).map(([k, v]) => `${LABELS[k]} = ${v}`).join(", ");
    statusLine.textContent = `${data.id} · ${data.elapsed_ms} ms` + (used ? ` · ${used}` : "");
    data.notices.forEach((n) =>
      resultsDiv.append(el("p", { class: "notice" }, "PostgreSQL NOTICE: " + n)));
    if (data.results.length === 0) resultsDiv.append(el("p", {}, "The query returned no result set."));
    data.results.forEach((r) => {
      renderResult(resultsDiv, r);
      if (!isPlan(r)) {
        let info = `${r.rows.length} row${r.rows.length === 1 ? "" : "s"}`;
        if (r.truncated) info += " (display limited to the first 500)";
        resultsDiv.append(el("p", { class: "status" }, info));
      }
    });
  } catch (err) {
    statusLine.textContent = "";
    resultsDiv.append(el("p", { class: "error" }, "Could not reach the server: " + err));
  } finally {
    runButton.disabled = false;
  }
}

querySelect.addEventListener("change", showQuery);
runButton.addEventListener("click", runQuery);
paramsForm.addEventListener("submit", (e) => { e.preventDefault(); runQuery(); });
showQuery();

// ---------- B. live SQL console ----------
const editor = document.getElementById("live-sql");
const liveRun = document.getElementById("live-run");
const liveStatus = document.getElementById("live-status");
const liveResults = document.getElementById("live-results");

async function runLive() {
  liveRun.disabled = true;
  liveStatus.replaceChildren(el("p", { class: "status" }, "Running on PostgreSQL…"));
  liveResults.replaceChildren();
  try {
    const { data } = await postJSON("/sql", { sql: editor.value });
    liveStatus.replaceChildren();
    if (!data.ok) {
      const title = data.stage === "validation"
        ? "Query rejected (read-only console)"
        : "Query failed — PostgreSQL error";
      const box = el("div", { class: "error" });
      box.append(el("strong", {}, title));
      box.append(el("pre", {}, data.error));
      liveStatus.append(box);
      return;
    }
    const box = el("div", { class: "success" });
    box.append(el("strong", {}, "Query executed successfully"));
    const rowsText = data.kind === "explain"
      ? `Plan lines: ${data.row_count}`
      : `Rows: ${data.row_count}` +
        (data.truncated ? ` (showing the first ${data.max_rows}; add LIMIT to see fewer)` : "");
    box.append(el("div", {}, rowsText));
    box.append(el("div", {}, `Execution time: ${data.elapsed_ms} ms`));
    liveStatus.append(box);
    data.notices.forEach((n) =>
      liveResults.append(el("p", { class: "notice" }, "PostgreSQL NOTICE: " + n)));
    if (data.kind === "explain") {
      liveResults.append(el("pre", { class: "plan" }, data.plan.join("\n")));
    } else if (data.row_count === 0) {
      liveResults.append(el("p", {}, "The query returned 0 rows."));
      renderResult(liveResults, data);
    } else {
      renderResult(liveResults, data);
    }
  } catch (err) {
    liveStatus.replaceChildren(el("p", { class: "error" }, "Could not reach the server: " + err));
  } finally {
    liveRun.disabled = false;
  }
}

liveRun.addEventListener("click", runLive);
document.getElementById("live-clear").addEventListener("click", () => {
  editor.value = "";
  liveStatus.replaceChildren();
  liveResults.replaceChildren();
  editor.focus();
});
editor.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); runLive(); }
});
document.querySelectorAll(".load-sample").forEach((button) => {
  button.addEventListener("click", () => {
    editor.value = SAMPLES[Number(button.dataset.index)][1];
    liveStatus.replaceChildren();
    liveResults.replaceChildren();
    editor.scrollIntoView({ behavior: "smooth", block: "center" });
    editor.focus();
  });
});
document.getElementById("copy-to-live").addEventListener("click", () => {
  editor.value = CATALOG[querySelect.value].sql;
  liveStatus.replaceChildren(el("p", { class: "hint" },
    `Copied ${querySelect.value} from the project files. Edit it, then Run Query ` +
    "(the console runs one statement at a time)."));
  liveResults.replaceChildren();
  editor.scrollIntoView({ behavior: "smooth", block: "center" });
});

// ---------- A. search around a location ----------
const locStatus = document.getElementById("loc-status");
const locResults = document.getElementById("loc-results");
const locMode = document.getElementById("loc-mode");
const locToLive = document.getElementById("loc-to-live");
let lastLocationSql = "";

function updateLocationMode() {
  const radius = locMode.value === "radius";
  document.getElementById("loc-radius-box").hidden = !radius;
  document.getElementById("loc-limit-box").hidden = radius;
}

async function runLocation() {
  const radius = locMode.value === "radius";
  const body = {
    lat: document.getElementById("loc-lat").value,
    lon: document.getElementById("loc-lon").value,
    category: document.getElementById("loc-category").value,
    mode: locMode.value,
    radius_m: document.getElementById("loc-radius").value,
    limit: radius ? 500 : document.getElementById("loc-limit").value,
  };
  const button = document.getElementById("loc-run");
  button.disabled = true;
  locStatus.replaceChildren(el("p", { class: "status" }, "Searching in PostGIS…"));
  locResults.replaceChildren();
  try {
    const { data } = await postJSON("/nearby", body);
    locStatus.replaceChildren();
    if (!data.ok) {
      const box = el("div", { class: "error" });
      box.append(el("strong", {}, "Search not run"));
      box.append(el("pre", {}, data.error));
      locStatus.append(box);
      return;
    }
    const box = el("div", { class: "success" });
    box.append(el("strong", {}, "Query executed successfully"));
    box.append(el("div", {}, `Point: ${body.lat}, ${body.lon} — ` +
      (data.ward ? `inside ${data.ward}` : "not inside a BMC ward")));
    box.append(el("div", {}, `Rows: ${data.row_count} · Execution time: ${data.elapsed_ms} ms`));
    locStatus.append(box);
    if (!data.inside_extract) {
      locStatus.append(el("p", { class: "notice" },
        "This point is outside the Mumbai data area (lon 72.75–73.05, lat 18.85–19.30), " +
        "so nearby results may be far away or empty."));
    }
    if (data.row_count === 0) locResults.append(el("p", {}, "No places found."));
    else renderResult(locResults, data);
    lastLocationSql = data.sql;
    document.getElementById("loc-sql").textContent = data.sql;
    document.getElementById("loc-sql-box").hidden = false;
    locToLive.disabled = false;
  } catch (err) {
    locStatus.replaceChildren(el("p", { class: "error" }, "Could not reach the server: " + err));
  } finally {
    button.disabled = false;
  }
}

locMode.addEventListener("change", updateLocationMode);
document.getElementById("loc-run").addEventListener("click", runLocation);
document.querySelectorAll("#location input").forEach((input) =>
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") runLocation(); }));
document.getElementById("loc-station").addEventListener("change", (e) => {
  if (!e.target.value) return;
  const [lat, lon] = e.target.value.split(",");
  document.getElementById("loc-lat").value = lat;
  document.getElementById("loc-lon").value = lon;
});
document.getElementById("loc-mine").addEventListener("click", () => {
  if (!navigator.geolocation) {
    locStatus.replaceChildren(el("p", { class: "notice" }, "This browser cannot share its location."));
    return;
  }
  navigator.geolocation.getCurrentPosition(
    (pos) => {
      document.getElementById("loc-lat").value = pos.coords.latitude.toFixed(6);
      document.getElementById("loc-lon").value = pos.coords.longitude.toFixed(6);
    },
    (err) => locStatus.replaceChildren(el("p", { class: "notice" }, "Location not available: " + err.message)));
});
locToLive.addEventListener("click", () => {
  editor.value = lastLocationSql;
  liveStatus.replaceChildren(el("p", { class: "hint" },
    "Loaded the location search SQL. Change it and click Run Query."));
  liveResults.replaceChildren();
  editor.scrollIntoView({ behavior: "smooth", block: "center" });
});
updateLocationMode();
