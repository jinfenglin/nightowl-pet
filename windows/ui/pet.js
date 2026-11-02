import { invoke, listen, fileURL, setEnglish, L } from "./common.js";

const $ = (s) => document.querySelector(s);
const sprite = $("#sprite");
const fx = $("#fx");
const HEAD = { x: 140, y: 262 };
/** Time from a hit's start until it lands; matches the HP drop in Rust. */
const IMPACT = { lightning: 80, slap: 120, can: 380 };

let state = { hp: 100, maxHp: 100, art: {} };
let lastHitAt = -Infinity;
let hideThreatTimer;

// ---- state ----

function render() {
  const hp = state.hp;
  const pose = hp <= 0 ? "dead" : performance.now() - lastHitAt < 380 ? "hurt" : hp < 30 ? "low" : "normal";
  const own = state.art[`pet/${pose}`];
  const src = own || state.art["pet/normal"];
  sprite.className = own || pose === "normal" ? "" : `fallback-${pose}`;
  if (src) {
    const url = fileURL(src);
    if (sprite.dataset.src !== url) { sprite.src = url; sprite.dataset.src = url; }
    sprite.style.display = "";
    $("#placeholder").style.display = "none";
  } else {
    sprite.style.display = "none";
    $("#placeholder").style.display = "block";
  }

  const ratio = Math.max(0, Math.min(1, hp / state.maxHp));
  $("#hp .fill").style.transform = `scaleX(${ratio})`;
  $("#hp .value").textContent = hp;
  $("#hp").classList.toggle("low", hp < 30 && hp > 0);
  $("#breathe").style.animationPlayState = hp <= 0 ? "paused" : "running";
}

function applyState(next) {
  state = next;
  setEnglish(next.english);
  const cloud = next.art["fx/cloud"];
  $("#cloud").src = cloud ? fileURL(cloud) : "";
  render();
}

// ---- speech ----

let speechTimer;
function say(text, seconds) {
  const bubble = $("#bubble");
  bubble.textContent = text;
  bubble.classList.add("show");
  clearTimeout(speechTimer);
  speechTimer = setTimeout(() => bubble.classList.remove("show"), seconds * 1000);
}

// ---- effects helpers ----

function spawn(className, x, y, html = "") {
  const el = document.createElement("div");
  el.className = `fx ${className}`;
  el.style.left = `${x}px`;
  el.style.top = `${y}px`;
  el.innerHTML = html;
  fx.appendChild(el);
  return el;
}

function play(el, keyframes, options) {
  const anim = el.animate(keyframes, { fill: "forwards", ...options });
  anim.onfinish = () => el.remove();
  return anim;
}

function number(text, kind) {
  const el = spawn(`number ${kind}`, HEAD.x - 20 + (Math.random() * 40 - 20), HEAD.y - 8, text);  // below the HP bar
  const dx = Math.random() * 24 - 12;
  play(el, [
    { transform: "translate(0, 10px) scale(0.3)", opacity: 0 },
    { transform: "translate(0, -6px) scale(1.25)", opacity: 1, offset: 0.15 },
    { transform: "translate(0, -14px) scale(1)", opacity: 1, offset: 0.35 },
    { transform: `translate(${dx}px, -54px) scale(0.95)`, opacity: 0 },
  ], { duration: 1000, easing: "ease-out" });
}

function pow(text, x, y, color, tilt) {
  const el = spawn("pow", x - 46, y - 37, text);
  el.style.setProperty("--c", color);
  play(el, [
    { transform: `rotate(${tilt}deg) scale(0.2)`, opacity: 1 },
    { transform: `rotate(${tilt}deg) scale(1.18)`, opacity: 1, offset: 0.25 },
    { transform: `rotate(${tilt}deg) scale(1)`, opacity: 1, offset: 0.7 },
    { transform: `rotate(${tilt}deg) scale(1)`, opacity: 0 },
  ], { duration: 560 });
}

function sparks(x, y, color, count = 8) {
  for (let i = 0; i < count; i++) {
    const el = spawn("spark", x - 3, y - 3);
    el.style.setProperty("--c", color);
    const a = Math.random() * Math.PI * 2;
    const r = 26 + Math.random() * 30;
    play(el, [
      { transform: "translate(0,0) scale(1)", opacity: 1 },
      { transform: `translate(${Math.cos(a) * r}px, ${Math.sin(a) * r + 14}px) scale(0.2)`, opacity: 0 },
    ], { duration: 420 + Math.random() * 200, easing: "cubic-bezier(0.2, 0.8, 0.4, 1)" });
  }
}

function flashLight(x, y, radius, color) {
  const el = spawn("flashlight", x - radius, y - radius);
  el.style.width = el.style.height = `${radius * 2}px`;
  el.style.background = `radial-gradient(circle, ${color}, transparent 70%)`;
  play(el, [{ opacity: 1 }, { opacity: 0 }], { duration: 240, easing: "ease-out" });
}

/** White flash, hit-stop shake, damage number. */
function impact(amount, big) {
  lastHitAt = performance.now();
  render();
  setTimeout(render, 400);
  sprite.classList.add("flash");
  setTimeout(() => sprite.classList.remove("flash"), 70);
  $("#body").animate(
    [{ transform: "translateX(0)" }, { transform: "translateX(-8px)" }, { transform: "translateX(7px)" },
     { transform: "translateX(-4px)" }, { transform: "translateX(2px)" }, { transform: "translateX(0)" }],
    { duration: 320, easing: "ease-out" });
  number(`-${amount}`, big ? "damage big" : "damage");
}

// ---- attacks ----

function showThreat(style) {
  clearTimeout(hideThreatTimer);
  if (style === "lightning") {
    const hasArt = !!state.art["fx/cloud"];
    $("#cloud").classList.toggle("show", hasArt);
    $("#cloud-fallback").classList.toggle("show", !hasArt);
  }
  if (style === "can") {
    const idle = state.art["fx/thrower-idle"];
    const thrower = $("#thrower");
    if (idle) { thrower.src = fileURL(idle); thrower.classList.add("show"); }
  }
}

function hideThreat() {
  hideThreatTimer = setTimeout(() => {
    for (const id of ["#cloud", "#cloud-fallback", "#thrower"]) $(id).classList.remove("show");
  }, 1600);
}

/** A jagged bolt from the cloud to the head: midpoint displacement. */
function boltPoints(x0, y0, x1, y1, roughness) {
  let pts = [[x0, y0], [x1, y1]];
  for (let pass = 0, spread = roughness; pass < 4; pass++, spread /= 2) {
    const next = [pts[0]];
    for (let i = 1; i < pts.length; i++) {
      const [ax, ay] = pts[i - 1], [bx, by] = pts[i];
      next.push([(ax + bx) / 2 + (Math.random() * 2 - 1) * spread, (ay + by) / 2], pts[i]);
    }
    pts = next;
  }
  return pts.map((p) => p.join(",")).join(" ");
}

function lightning(amount, index) {
  const svg = $("#bolts");
  const x0 = 140 + (Math.random() * 60 - 30);
  const pts = boltPoints(x0, 186, HEAD.x + (Math.random() * 16 - 8), HEAD.y, 22);
  const layers = [[11, "rgba(150,110,255,0.35)"], [4.5, "#a98bff"], [1.8, "#ffffff"]];
  const lines = layers.map(([width, color]) => {
    const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    line.setAttribute("points", pts);
    line.setAttribute("stroke", color);
    line.setAttribute("stroke-width", width);
    svg.appendChild(line);
    return line;
  });
  lines.forEach((l) => l.animate([{ opacity: 1 }, { opacity: 1, offset: 0.5 }, { opacity: 0 }], { duration: 220 }).onfinish = () => l.remove());
  $("#cloud").classList.add("lit");
  setTimeout(() => $("#cloud").classList.remove("lit"), 120);
  flashLight(HEAD.x, HEAD.y, 90, "rgba(200,170,255,0.85)");
  setTimeout(() => {
    impact(amount, index === 2);
    sparks(HEAD.x, HEAD.y, "#a98bff", 10);
  }, IMPACT.lightning);
}

function slap(amount, index) {
  const side = index % 2 ? -1 : 1;
  const art = state.art["fx/hand"];
  const el = spawn("hand", HEAD.x + side * 95 - 35, HEAD.y - 30, art ? `<img src="${fileURL(art)}">` : "🖐️");
  const flip = side < 0 ? -1 : 1;
  play(el, [
    { transform: `translateX(0) scaleX(${flip}) rotate(${-side * 20}deg)`, opacity: 0 },
    { transform: `translateX(${-side * 55}px) scaleX(${flip}) rotate(0deg)`, opacity: 1, offset: 0.35 },
    { transform: `translateX(${-side * 50}px) scaleX(${flip})`, opacity: 1, offset: 0.55 },
    { transform: `translateX(${side * 10}px) scaleX(${flip})`, opacity: 0 },
  ], { duration: 340, easing: "ease-out" });
  setTimeout(() => {
    impact(amount, index === 5);
    const words = L("啪!|啪!!|PIA!", "SLAP!|WHAP!|PIA!").split("|");
    pow(words[Math.floor(Math.random() * words.length)], HEAD.x + side * 62, HEAD.y + 10, "var(--red)", side * -12);
  }, IMPACT.slap);
}

function throwCan(amount, index) {
  const thrower = $("#thrower");
  const throwArt = state.art["fx/thrower-throw"];
  if (throwArt && thrower.classList.contains("show")) {
    thrower.src = fileURL(throwArt);
    setTimeout(() => { if (state.art["fx/thrower-idle"]) thrower.src = fileURL(state.art["fx/thrower-idle"]); }, 450);
  }
  const art = state.art["fx/can"];
  const el = spawn("can", 0, 0, art ? `<img src="${fileURL(art)}">` : "<span>🥫</span>");
  const from = { x: 200, y: 318 };
  // Arc to the head, bonk, then bounce off to the right and drop.
  const frames = [];
  for (let i = 0; i <= 10; i++) {
    const u = i / 10;
    const x = from.x + (HEAD.x - from.x) * u;
    const y = from.y + (HEAD.y - 10 - from.y) * u - 70 * Math.sin(u * Math.PI);
    frames.push({ transform: `translate(${x - 13}px, ${y - 13}px) rotate(${-u * 900}deg) scale(${0.55 + 0.6 * u})`, offset: u * 0.38 });
  }
  frames.push({ transform: `translate(${HEAD.x + 40}px, ${HEAD.y - 70}px) rotate(-1100deg) scale(1.15)`, offset: 0.6 });
  frames.push({ transform: `translate(${HEAD.x + 80}px, 380px) rotate(-1300deg) scale(1.15)`, offset: 0.9, opacity: 1 });
  frames.push({ transform: `translate(${HEAD.x + 95}px, 372px) rotate(-1340deg) scale(1.15)`, opacity: 0 });
  play(el, frames, { duration: 1000, easing: "linear" });
  setTimeout(() => {
    impact(amount, index === 2);
    pow(L("咚!", "BONK!"), HEAD.x + 62, HEAD.y + 12, "var(--gold)", 10);  // beside the head, clear of the HP bar
  }, IMPACT.can);
}

function heal(amount) {
  number(`+${amount}`, "heal");
  sparks(HEAD.x, HEAD.y + 20, "#73b3ff", 12);
  render();
}

// ---- mouse: drag anywhere on the pet, double-click to poke, right-click for the menu ----

const hitArea = $("#hit");
let down = null;
hitArea.addEventListener("mousedown", (e) => { if (e.button === 0) down = { x: e.screenX, y: e.screenY }; });
window.addEventListener("mousemove", (e) => {
  if (down && e.buttons & 1 && Math.hypot(e.screenX - down.x, e.screenY - down.y) > 3) {
    down = null;
    window.__TAURI__.window.getCurrentWindow().startDragging();
  }
});
window.addEventListener("mouseup", () => { down = null; });
hitArea.addEventListener("dblclick", () => invoke("poke"));
window.addEventListener("contextmenu", (e) => { e.preventDefault(); invoke("show_context_menu"); });

function reportHitRect() {
  const r = hitArea.getBoundingClientRect();
  invoke("set_hit_rect", { x: r.left, y: r.top, width: r.width, height: r.height });
}

// ---- wiring ----

listen("state", (e) => applyState(e.payload));
listen("speech", (e) => say(e.payload.text, e.payload.seconds));
listen("heal", (e) => heal(e.payload.amount));
listen("attack", (e) => {
  if (e.payload.active) showThreat(e.payload.style); else hideThreat();
});
listen("hit", (e) => {
  const { amount, style, index } = e.payload;
  ({ lightning, slap, can: throwCan })[style](amount, index);
});

applyState(await invoke("get_state"));
reportHitRect();
