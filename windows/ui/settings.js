import { invoke, listen, fileURL, setEnglish, L, slotTitle, STYLES } from "./common.js";

const content = document.querySelector("#content");
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

let tab = "general";
let settings = {};
let library = [];
let pet = { hp: 100, maxHp: 100, busy: null, art: {} };
let prompts = {};

const TABS = [
  ["general", "通用", "General"],
  ["appearance", "形象", "Appearance"],
  ["generate", "素材生成", "Generate"],
  ["rules", "规则", "Rules"],
  ["log", "记录", "Log"],
  ["backup", "备份", "Backup"],
];

async function reload() {
  let list;
  [settings, library, pet, list] = await Promise.all([
    invoke("get_settings"), invoke("get_library"), invoke("get_state"), invoke("get_prompts")]);
  prompts = Object.fromEntries(list);
  setEnglish(settings.resolvedEnglish);
  document.documentElement.lang = settings.resolvedEnglish ? "en" : "zh-CN";
  render();
}

const set = (key, value) => invoke("set_setting", { key, value });

// Changes arrive all the time (HP ticks, generation progress). Don't rebuild the page under a field
// that's being edited; catch up when it loses focus.
let pendingRender = false;
const editing = () => content.contains(document.activeElement) && /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
content.addEventListener("focusout", () => setTimeout(() => { if (pendingRender && !editing()) render(); }));

function render() {
  if (editing()) { pendingRender = true; return; }
  pendingRender = false;
  document.querySelector("#tabs").innerHTML = TABS.map(([id, zh, en]) =>
    `<button data-tab="${id}" class="${id === tab ? "active" : ""}">${L(zh, en)}</button>`).join("");
  ({ general, appearance, generate, rules, log, backup })[tab]();
}

document.querySelector("#tabs").addEventListener("click", (e) => {
  const id = e.target.dataset.tab;
  if (id) { tab = id; render(); content.scrollTop = 0; }
});

// ---- 通用 ----

async function general() {
  const autostart = await invoke("get_autostart");
  content.innerHTML = `
    <h3>${L("启动", "Startup")}</h3>
    <div class="card">
      <div class="row"><span class="label">${L("开机时自动启动 DeskPet", "Open DeskPet at login")}</span>
        <label class="switch"><input type="checkbox" id="autostart" ${autostart ? "checked" : ""}><span></span></label></div>
    </div>
    <p class="footer" id="autostart-error"></p>
    <h3>${L("语言", "Language")}</h3>
    <div class="card">
      <div class="row"><span class="label">${L("界面语言", "Language")}</span>
        <select id="language">
          ${[["system", L("跟随系统", "System")], ["zh", "简体中文"], ["en", "English"]].map(([v, t]) =>
            `<option value="${v}" ${settings.language === v ? "selected" : ""}>${t}</option>`).join("")}
        </select></div>
    </div>
    <p class="footer">${L("菜单、设置和宠物说的话都会切换。", "Switches the menus, settings and what the pet says.")}</p>`;
  content.querySelector("#autostart").onchange = async (e) => {
    try {
      await invoke("set_autostart", { enabled: e.target.checked });
      content.querySelector("#autostart-error").textContent = "";
    } catch (err) {
      e.target.checked = !e.target.checked;
      content.querySelector("#autostart-error").textContent = L("设置失败：", "Couldn't change it: ") + err;
    }
  };
  content.querySelector("#language").onchange = (e) => set("language", e.target.value);
}

// ---- 形象 ----

function picker(folder, noneLabel) {
  const slot = library.find((s) => s.folder === folder) || { files: [], selected: null };
  const n = slot.files.length;
  return `
    <div class="row picker" data-folder="${folder}">
      <div class="head">
        <span class="title">${slotTitle(folder)}</span>
        <span class="count">${L(`${n} 张`, n === 1 ? "1 image" : `${n} images`)}</span>
        <button class="btn small" data-action="import">${L("导入…", "Import…")}</button>
        <button class="btn small" data-action="reveal">${L("打开文件夹", "Open Folder")}</button>
      </div>
      <div class="tiles">
        <div class="tile ${slot.selected ? "" : "selected"}" data-name="">${noneLabel}</div>
        ${slot.files.map((f) => `
          <div class="tile ${slot.selected === f.name ? "selected" : ""}" data-name="${esc(f.name)}" title="${esc(f.name)}">
            <img src="${fileURL(f.path)}" loading="lazy">
          </div>`).join("")}
      </div>
    </div>`;
}

function appearance() {
  const style = settings.attackStyle || "lightning";
  const current = STYLES.find((s) => s[0] === style) || STYLES[0];
  content.innerHTML = `
    <h3>${L("宠物状态图", "Pet Poses")}</h3>
    <div class="card">${["pet/normal", "pet/low", "pet/hurt", "pet/dead"].map((f) => picker(f, L("滤镜效果", "Filter"))).join("")}</div>
    <p class="footer">${L("「滤镜效果」= 不用图片，用变灰 / 倒下 / 染红代替。", "“Filter” = no image; the pet is greyed out, tipped over or tinted red instead.")}</p>
    <h3>${L("攻击特效", "Attack Effect")}</h3>
    <div class="card">
      <div class="row"><div class="segmented">${STYLES.map(([id, zh, en]) =>
        `<button data-style="${id}" class="${id === style ? "active" : ""}">${L(zh, en)}</button>`).join("")}</div></div>
      <div class="row"><button class="btn" id="try">${L("试一下（不扣血）", "Try it (no damage)")}</button></div>
      ${current[3].map((f) => picker(f, L("代码绘制", "Drawn"))).join("")}
    </div>
    <p class="footer">${L("每类素材都在自己的文件夹里。点「打开文件夹」，把图片直接拖进去也会出现在这里；右键缩略图可以删除（移到回收站）。",
      "Each kind has its own folder. Click “Open Folder” and drop images in to add them here; right-click a thumbnail to delete it (moves to the Recycle Bin).")}</p>`;

  content.querySelectorAll("[data-style]").forEach((b) => b.onclick = () => set("attackStyle", b.dataset.style));
  content.querySelector("#try").onclick = () => invoke("test_attack");
  content.querySelectorAll(".picker").forEach((row) => {
    const folder = row.dataset.folder;
    row.querySelector('[data-action="import"]').onclick = () => invoke("import_asset", { folder });
    row.querySelector('[data-action="reveal"]').onclick = () => invoke("reveal_asset", { folder, name: null });
    row.querySelectorAll(".tile").forEach((tile) => {
      const name = tile.dataset.name || null;
      tile.onclick = () => invoke("select_asset", { folder, name });
      if (name) tile.oncontextmenu = (e) => { e.preventDefault(); tileMenu(e, folder, name); };
    });
  });
}

function tileMenu(e, folder, name) {
  document.querySelector(".menu")?.remove();
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.style.left = `${Math.min(e.clientX, innerWidth - 200)}px`;
  menu.style.top = `${Math.min(e.clientY, innerHeight - 120)}px`;
  menu.innerHTML = `
    <button data-a="use">${L("使用这张", "Use This")}</button>
    <button data-a="reveal">${L("在文件夹中显示", "Show in Folder")}</button><hr>
    <button data-a="delete">${L("删除（移到回收站）", "Delete (Move to Recycle Bin)")}</button>`;
  menu.onclick = (ev) => {
    const a = ev.target.dataset.a;
    if (a === "use") invoke("select_asset", { folder, name });
    if (a === "reveal") invoke("reveal_asset", { folder, name });
    if (a === "delete") invoke("delete_asset", { folder, name });
    menu.remove();
  };
  document.body.appendChild(menu);
  setTimeout(() => addEventListener("click", () => menu.remove(), { once: true }));
}

// ---- 素材生成 ----

const PRESETS = {
  openAI: ["gpt-image-1", "gpt-image-1-mini", "dall-e-2"],
  gemini: ["gemini-2.5-flash-image", "gemini-2.0-flash-preview-image-generation"],
};
const expanded = new Set();

function thumb(folder) {
  const path = pet.art[folder];
  return `<div class="thumb">${path ? `<img src="${fileURL(path)}">` : ""}</div>`;
}

function promptEditor(id, title) {
  const p = prompts[id];
  return `
    <div class="prompt" data-prompt="${id}">
      <div class="prompt-head"><span>${title}</span>
        <button class="btn small" data-reset ${p.value === p.default ? "disabled" : ""}>${L("恢复默认", "Reset")}</button></div>
      <textarea spellcheck="false">${esc(p.value)}</textarea>
    </div>`;
}

function genRow(folder, note, button, action) {
  const slot = library.find((s) => s.folder === folder) || { files: [] };
  const n = slot.files.length;
  const busy = !!pet.busy;
  const disabled = busy || (folder.startsWith("pet/") && folder !== "pet/normal" && !pet.art["pet/normal"]);
  return `
    <div class="row gen" data-folder="${folder}">
      <div class="gen-main">
        ${thumb(folder)}
        <div class="gen-text"><div class="title">${slotTitle(folder)}</div>
          <div class="note">${note ?? L(`${n} 张已生成 / 导入`, n === 1 ? "1 generated / imported" : `${n} generated / imported`)}</div></div>
        <button class="btn small" data-toggle>${expanded.has(folder) ? L("收起提示词", "Hide Prompt") : L("提示词", "Prompt")}</button>
        <button class="btn small" data-copy>${L("复制提示词", "Copy Prompt")}</button>
        <button class="btn small primary" data-generate="${action}" ${disabled ? "disabled" : ""}>${button}</button>
      </div>
      ${expanded.has(folder) ? promptEditor(folder, folder.startsWith("pet/") ? L("提示词", "Prompt") : L("素材描述", "Description")) : ""}
    </div>`;
}

function generate() {
  const provider = settings.provider === "gemini" ? "gemini" : "openAI";
  const gemini = provider === "gemini";
  const field = (key, label, attrs = "") =>
    `<div class="row"><span class="label">${label}</span><input class="wide" data-text="${key}" value="${esc(settings[key] ?? "")}" ${attrs}></div>`;
  const busy = !!pet.busy;
  content.innerHTML = `
    ${busy ? `<div class="card busy"><div class="row"><span class="spinner"></span><span>${esc(pet.busy)}</span></div></div>` : ""}
    <h3>${L("AI 设置", "AI Settings")}</h3>
    <div class="card">
      <div class="row"><span class="label">${L("服务商", "Provider")}</span>
        <div class="segmented narrow">
          <button data-provider="openAI" class="${gemini ? "" : "active"}">${L("OpenAI 兼容接口", "OpenAI-compatible")}</button>
          <button data-provider="gemini" class="${gemini ? "active" : ""}">Google Gemini</button></div></div>
      ${gemini
        ? field("geminiKey", L("API Key（留空读取 GEMINI_API_KEY）", "API key (blank = use GEMINI_API_KEY)"), 'type="password"')
        : field("apiKey", L("API Key（留空读取 OPENAI_API_KEY）", "API key (blank = use OPENAI_API_KEY)"), 'type="password"') + field("apiBase", "API Base URL")}
      ${field(gemini ? "geminiModel" : "imageModel", L("模型", "Model"), 'list="model-presets"')}
      <datalist id="model-presets">${PRESETS[provider].map((m) => `<option value="${m}">`).join("")}</datalist>
      ${field("proxy", L("代理（可选，如 http://127.0.0.1:7890）", "Proxy (optional, e.g. http://127.0.0.1:7890)"))}
    </div>
    <p class="footer">${gemini
      ? L("在 aistudio.google.com 获取 Key。Gemini 输出白底图，会自动抠成透明。", "Get a key at aistudio.google.com. Gemini returns white backgrounds, which are made transparent automatically.")
      : L("任何兼容 OpenAI 图像接口的服务都可以：改 Base URL 和模型名即可。", "Any service compatible with the OpenAI images API works: just change the base URL and model name.")}</p>

    <h3>${L("宠物状态图", "Pet Poses")}</h3>
    <div class="card">
      ${genRow("pet/normal", L("从一张真实照片生成，完成后会接着生成另外 3 张", "Made from a real photo; the other 3 poses follow automatically"), L("选照片生成…", "Choose Photo…"), "character")}
      ${["pet/low", "pet/hurt", "pet/dead"].map((f) => genRow(f, L("以当前满血图为参考", "Uses the current full-HP image as reference"), L("生成", "Generate"), "pose")).join("")}
      <div class="row"><button class="btn" id="gen-poses" ${busy || !pet.art["pet/normal"] ? "disabled" : ""}>${L("生成残血 / 受击 / 阵亡", "Generate Low HP / Hit / Knocked Out")}</button></div>
    </div>

    <h3>${L("特效素材", "Effect Art")}</h3>
    <div class="card">
      <div class="row">${promptEditor("fxStyle", L("风格（所有特效素材共用）", "Style (shared by all effect art)"))}</div>
      ${["fx/cloud", "fx/thrower-idle", "fx/thrower-toss", "fx/thrower-throw", "fx/can", "fx/hand"].map((f) =>
        genRow(f, f === "fx/thrower-toss" || f === "fx/thrower-throw"
          ? L(`以当前「${slotTitle("fx/thrower-idle")}」为参考`, `Uses the current “${slotTitle("fx/thrower-idle")}” as reference`) : null,
          L("生成", "Generate"), "effect")).join("")}
      <div class="row"><button class="btn" id="gen-effects" ${busy ? "disabled" : ""}>${L("生成全部特效素材", "Generate All Effect Art")}</button></div>
    </div>
    <p class="footer">${L("生成的图片按类型存进素材库对应的文件夹（如 pet/hurt、fx/cloud），文件名带时间戳，不会覆盖旧图，并自动设为当前使用。想换回旧图或删除，去「形象」页。没有 API Key 时，可以「复制提示词」到 Gemini / ChatGPT 网页版生成，再到「形象」页导入。",
      "Generated images are saved by type into the asset library (e.g. pet/hurt, fx/cloud) with a timestamp, never overwriting older ones, and become the current choice. To switch back or delete, go to Appearance. Without an API key, use “Copy Prompt” in the Gemini / ChatGPT web app, then import the result in Appearance.")}</p>`;

  content.querySelectorAll("[data-provider]").forEach((b) => b.onclick = () => set("provider", b.dataset.provider));
  content.querySelectorAll("[data-text]").forEach((el) => el.onchange = () => {
    const v = el.value.trim();
    set(el.dataset.text, v || null);
  });
  content.querySelectorAll(".gen").forEach((row) => {
    const folder = row.dataset.folder;
    row.querySelector("[data-toggle]").onclick = () => {
      expanded.has(folder) ? expanded.delete(folder) : expanded.add(folder);
      render();
    };
    row.querySelector("[data-copy]").onclick = () => invoke("copy_prompt", { folder });
    row.querySelector("[data-generate]").onclick = (e) => {
      const action = e.target.dataset.generate;
      if (action === "character") invoke("create_character");
      if (action === "pose") invoke("generate_poses", { folders: [folder] });
      if (action === "effect") invoke("generate_effects", { folders: [folder] });
    };
  });
  content.querySelectorAll("[data-prompt]").forEach((box) => {
    const p = prompts[box.dataset.prompt];
    const textarea = box.querySelector("textarea");
    // Saving the default (or nothing) clears the setting, so future default changes apply.
    const save = (v) => set(p.key, v.trim() && v !== p.default ? v : null);
    textarea.onchange = () => save(textarea.value);
    box.querySelector("[data-reset]").onclick = () => save(p.default);
  });
  content.querySelector("#gen-poses").onclick = () => invoke("generate_poses", { folders: ["pet/low", "pet/hurt", "pet/dead"] });
  content.querySelector("#gen-effects").onclick = () =>
    invoke("generate_effects", { folders: ["fx/cloud", "fx/thrower-idle", "fx/thrower-toss", "fx/thrower-throw", "fx/can", "fx/hand"] });
}

// ---- 备份 ----

function backup() {
  content.innerHTML = `
    <h3>${L("导入 / 导出一整套配置", "Import / Export a Complete Config")}</h3>
    <div class="card">
      <div class="row"><button class="btn" id="export">${L("导出配置…", "Export Config…")}</button>
        <label class="check"><input type="checkbox" id="secrets"> ${L("包含 API Key（分享给别人时不要勾选）", "Include API keys (leave off when sharing)")}</label></div>
      <div class="row"><button class="btn" id="import" ${pet.busy ? "disabled" : ""}>${L("导入配置…", "Import Config…")}</button></div>
    </div>
    <p class="footer" id="backup-error" style="color:#d33"></p>
    <p class="footer">${L("包含：四张状态图、特效素材、规则（宵禁 / 扣血 / 久坐 / 奖励）、攻击特效、服务商与模型、全部提示词。和 macOS 版的配置文件通用。<br>API Key 默认不导出；导入的文件没有 Key 时保留现在的 Key。<br>不包含：当前 HP、扣血记录、代理、语言和窗口位置。",
      "Includes: the four poses, effect art, rules (curfew / damage / sitting / reward), attack effect, provider and model, and all prompts. Works with config files from the macOS version.<br>API keys aren't exported unless you tick the box; importing a file without keys keeps your current ones.<br>Not included: current HP, the log, proxy, language and window position.")}</p>`;
  const showError = (e) => { content.querySelector("#backup-error").textContent = String(e); };
  content.querySelector("#export").onclick = () =>
    invoke("export_config", { includeSecrets: content.querySelector("#secrets").checked }).catch(showError);
  content.querySelector("#import").onclick = () => invoke("import_config").catch(showError);
}

// ---- 规则 ----

const toTime = (m) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
const fromTime = (t) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; };

function rules() {
  const num = (key, min, max, step = 1) =>
    `<input type="number" data-key="${key}" min="${min}" max="${max}" step="${step}" value="${settings[key]}">`;
  const sitting = settings.sittingEnabled;
  content.innerHTML = `
    <h3>${L(`血量 · 当前 ${pet.hp} / ${pet.maxHp}`, `HP · now ${pet.hp} / ${pet.maxHp}`)}</h3>
    <div class="card"><div class="row">
      <button class="btn" id="heal" ${pet.hp >= pet.maxHp ? "disabled" : ""}>${L("回满血（作弊）", "Full Heal (Cheat)")}</button></div></div>

    <h3>${L("熬夜惩罚", "Late-Night Penalty")}</h3>
    <div class="card">
      <div class="row"><span class="label">${L("宵禁开始", "Curfew starts")}</span><input type="time" data-time="curfewStart" value="${toTime(settings.curfewStart)}"></div>
      <div class="row"><span class="label">${L("宵禁结束", "Curfew ends")}</span><input type="time" data-time="curfewEnd" value="${toTime(settings.curfewEnd)}"></div>
      <div class="row"><span class="label">${L("宵禁期间每使用 1 分钟扣血（HP）", "HP lost per minute of use during curfew")}</span>${num("lateNightDamage", 1, 20)}</div>
      <div class="row"><span class="label">${L("整晚没违规，早上回复（HP）", "HP regained after a clean night")}</span>${num("goodNightHeal", 0, 100, 5)}</div>
    </div>

    <h3>${L("久坐惩罚", "Sitting Penalty")}</h3>
    <div class="card">
      <div class="row"><span class="label">${L("启用", "Enabled")}</span>
        <label class="switch"><input type="checkbox" id="sitting" ${sitting ? "checked" : ""}><span></span></label></div>
      <div class="row"><span class="label">${L("连续使用超过多少分钟开始扣血", "Minutes of continuous use before HP loss")}</span>${num("sittingLimit", 15, 240, 15)}</div>
      <div class="row"><span class="label">${L("超时后每分钟扣血（HP）", "HP lost per minute after that")}</span>${num("sittingDamage", 1, 10)}</div>
      <div class="row"><span class="label">${L("离开多少分钟算休息", "Minutes away that count as a break")}</span>${num("breakMinutes", 1, 30)}</div>
    </div>`;
  content.querySelector("#heal").onclick = () => invoke("full_heal");
  content.querySelector("#sitting").onchange = (e) => set("sittingEnabled", e.target.checked);
  content.querySelectorAll("[data-time]").forEach((el) => el.onchange = () => el.value && set(el.dataset.time, fromTime(el.value)));
  content.querySelectorAll("[data-key]").forEach((el) => el.onchange = () => {
    const v = Math.max(+el.min, Math.min(+el.max, Math.round(+el.value)));
    if (!Number.isNaN(v)) set(el.dataset.key, v);
  });
  if (!sitting) content.querySelectorAll('[data-key^="sitting"], [data-key="breakMinutes"]').forEach((el) => el.disabled = true);
}

// ---- 记录 ----

function chart(days) {
  days = [...days].sort((a, b) => a.day.localeCompare(b.day));
  if (!days.length) return `<p class="footer" style="padding:12px 14px">${L("还没有数据。DeskPet 每天会记录一次最低血量，明天再来看看吧。", "No data yet. DeskPet records the lowest HP once a day. Check back tomorrow.")}</p>`;
  const W = 560, H = 190, left = 28, bottom = 20, top = 8;
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const dayIndex = (d) => 29 - Math.round((today - new Date(`${d}T00:00:00`)) / 86400000);
  const x = (i) => left + (i + 0.5) * (W - left) / 30;
  const y = (hp) => top + (1 - hp / 100) * (H - top - bottom);
  // Break the line where days are missing.
  const segments = [];
  let prev = null;
  for (const d of days) {
    const i = dayIndex(d.day);
    if (prev === null || i - prev > 1) segments.push([]);
    segments.at(-1).push(`${x(i)},${y(d.minHP)}`);
    prev = i;
  }
  const fmt = (offset) => { const d = new Date(today); d.setDate(d.getDate() - offset); return `${d.getMonth() + 1}/${d.getDate()}`; };
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">
    ${[0, 50, 100].map((v) => `<line class="grid" x1="${left}" x2="${W}" y1="${y(v)}" y2="${y(v)}"/><text class="axis" x="${left - 6}" y="${y(v) + 3}" text-anchor="end">${v}</text>`).join("")}
    <line class="low" x1="${left}" x2="${W}" y1="${y(30)}" y2="${y(30)}"/>
    <text class="axis" x="${left + 4}" y="${y(30) - 4}">${L("残血线 30", "Low line 30")}</text>
    ${segments.map((s) => `<polyline class="series" points="${s.join(" ")}"/>`).join("")}
    ${days.map((d) => `<circle class="dot" r="3.5" cx="${x(dayIndex(d.day))}" cy="${y(d.minHP)}"><title>${d.day}: ${d.minHP}</title></circle>`).join("")}
    ${[[0, 29], [15, 14], [29, 0]].map(([i, off]) => `<text class="axis" x="${x(i)}" y="${H - 4}" text-anchor="middle">${fmt(off)}</text>`).join("")}
  </svg>`;
}

async function log() {
  const [entries, days] = await Promise.all([invoke("get_log"), invoke("get_history")]);
  const time = (iso) => { const d = new Date(iso); return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; };
  content.innerHTML = `
    <h3>${L("每日最低血量 · 最近 30 天", "Daily Minimum HP · last 30 days")}</h3>
    <div class="card chart">${chart(days)}</div>
    <h3>${L("最近记录", "Recent")}</h3>
    <div class="card log">
      ${entries.length ? entries.slice(0, 100).map((e) => `
        <div class="row"><span class="time">${time(e.date)}</span>
          <span class="delta ${e.delta > 0 ? "plus" : "minus"}">${e.delta > 0 ? "+" : ""}${e.delta}</span>
          <span class="reason" title="${esc(e.reason)}">${esc(e.reason)}</span></div>`).join("")
        : `<div class="row" style="color:var(--muted)">${L("还没有记录", "Nothing yet")}</div>`}
    </div>`;
}

// Re-render on any change (language, HP, art), and rescan folders when the window comes back.
listen("state", reload);
addEventListener("focus", reload);
reload();
