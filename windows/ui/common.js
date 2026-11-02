// Shared by the pet and settings pages. Tauri's API comes in as a global (withGlobalTauri).
export const { invoke, convertFileSrc } = window.__TAURI__.core;
export const { listen } = window.__TAURI__.event;

// No devtools in the borderless pet window: send script errors to the app's console.
const report = (message) => invoke("log_js", { message: `${location.pathname}: ${message}` });
addEventListener("error", (e) => report(`${e.message} (${e.filename}:${e.lineno})`));
addEventListener("unhandledrejection", (e) => report(`unhandled: ${e.reason}`));

let english = false;
export const setEnglish = (value) => { english = value; };
export const isEnglish = () => english;

/** The string for the current UI language: L("中文", "English"). */
export const L = (zh, en) => (english ? en : zh);

/** Asset slots, same folders as the macOS version's library. */
export const SLOTS = {
  "pet/normal": ["满血", "Full HP"],
  "pet/low": ["残血", "Low HP"],
  "pet/hurt": ["受击", "Hit"],
  "pet/dead": ["阵亡", "Knocked out"],
  "fx/cloud": ["乌云", "Storm cloud"],
  "fx/thrower-idle": ["小人 · 待机", "Thrower · idle"],
  "fx/thrower-toss": ["小人 · 抛起", "Thrower · toss"],
  "fx/thrower-throw": ["小人 · 投掷", "Thrower · throw"],
  "fx/can": ["易拉罐", "Soda can"],
  "fx/hand": ["巴掌", "Slapping hand"],
};
export const slotTitle = (folder) => L(...SLOTS[folder]);

export const STYLES = [
  ["lightning", "⚡️ 雷击", "⚡️ Lightning", ["fx/cloud"]],
  ["slap", "🖐️ 连环耳光", "🖐️ Slaps", ["fx/hand"]],
  ["can", "🥫 丢易拉罐", "🥫 Can toss", ["fx/can", "fx/thrower-idle", "fx/thrower-toss", "fx/thrower-throw"]],
  ["random", "🎲 随机", "🎲 Random", ["fx/cloud", "fx/thrower-idle", "fx/thrower-toss", "fx/thrower-throw", "fx/can", "fx/hand"]],
];

/** Asset-protocol URL for an absolute file path (null stays null). */
export const fileURL = (path) => (path ? convertFileSrc(path) : null);
