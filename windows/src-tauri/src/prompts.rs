use crate::settings::Settings;
use serde::Serialize;

/// Prompts and their setting keys, identical to the macOS version so exported configs carry over.
/// A slot is identified by its library folder ("pet/low", "fx/thrower-toss", ...).

const CHARACTER: &str = "Turn the main subject of this photo into a cute chibi cartoon character for a desktop pet: \
full body, big head, bold clean outlines, flat vibrant colors, soft cel shading, friendly expression, \
centered, keep the recognizable features of the original, no text.";

const POSE_REFERENCE: &str = "Use the attached image as the character reference. Draw exactly the same character: same art style, \
colors, outfit and proportions, centered and at the same scale.";

const FX_REFERENCE: &str = "Use the attached image as the character reference. Draw exactly the same character, outfit, colors \
and art style, full body, at the same scale. ";

pub const FX_STYLE_KEY: &str = "fxStyle";
pub const FX_STYLE: &str = "Japanese anime illustration style like a polished key visual: crisp fine ink linework, cel \
shading with soft painterly highlights, subtle pencil cross-hatching texture, rich blacks, vivid red and electric blue accents, \
red and blue rim lighting. A single isolated subject, centered, fully visible, transparent background, no text, no frame.";

/// (folder, raw name used in macOS keys and config files)
pub const POSES: &[(&str, &str)] = &[("pet/normal", "normal"), ("pet/low", "low"), ("pet/hurt", "hurt"), ("pet/dead", "dead")];
pub const EFFECTS: &[(&str, &str)] = &[
    ("fx/cloud", "cloud"),
    ("fx/thrower-idle", "throwerIdle"),
    ("fx/thrower-toss", "throwerToss"),
    ("fx/thrower-throw", "throwerThrow"),
    ("fx/can", "can"),
    ("fx/hand", "hand"),
];

pub fn raw_name(folder: &str) -> Option<&'static str> {
    POSES.iter().chain(EFFECTS).find(|(f, _)| *f == folder).map(|(_, r)| *r)
}

/// The setting that holds the editable part of the slot's prompt.
pub fn key(folder: &str) -> String {
    match folder {
        "pet/normal" => "stylePrompt".into(),
        f if f.starts_with("pet/") => format!("posePrompt.{}", &f[4..]),
        f => format!("fxPrompt.{}", raw_name(f).unwrap_or_default()),
    }
}

pub fn default_for(folder: &str) -> String {
    match folder {
        "pet/normal" => CHARACTER.into(),
        "pet/low" => format!("{POSE_REFERENCE} Now at LOW HEALTH: exhausted and worn out, sweating, droopy half-closed eyes, slouching, a couple of band-aids, tired wobbly stance. No text."),
        "pet/hurt" => format!("{POSE_REFERENCE} Now GETTING HIT: flinching in pain, eyes squeezed shut, mouth open yelling \"ouch\", body recoiling, cartoon impact stars around the head. No text."),
        "pet/dead" => format!("{POSE_REFERENCE} Now KNOCKED OUT with zero health: lying flat on its back, eyes drawn as X marks, tongue sticking out, a small cute ghost floating up from the body. Comedic, not gory. No text."),
        "fx/cloud" => "A menacing dark storm cloud, volumetric and fluffy, deep charcoal and indigo tones, lit from within by a purple-blue lightning glow, a few small electric sparks under it. Wide horizontal shape, about 2:1.".into(),
        "fx/thrower-idle" => "A small mischievous chibi kid, full body, standing, red cap, blue hoodie, cheeky grin, one hand open and ready to catch, facing left.".into(),
        "fx/thrower-toss" => "Same kid, pose: right arm raised straight up with the palm open, having just tossed something upward, looking up.".into(),
        "fx/thrower-throw" => "Same kid, pose: dynamic overhand throw, throwing arm extended forward toward the left, leaning forward.".into(),
        "fx/can" => "A red aluminum soda can, slightly dented, standing upright, crisp metallic highlights, no logo or text.".into(),
        "fx/hand" => "A cartoon open hand mid-slap, seen from the side, palm facing right, fingers together, wrist at the left edge.".into(),
        _ => String::new(),
    }
}

fn saved_or(settings: &Settings, key: &str, default: String) -> String {
    match settings.string(key) {
        Some(s) if !s.trim().is_empty() => s,
        _ => default,
    }
}

/// The editable part (pose prompt, or effect subject), falling back to the default when empty.
pub fn editable(settings: &Settings, folder: &str) -> String {
    saved_or(settings, &key(folder), default_for(folder))
}

pub fn fx_style(settings: &Settings) -> String {
    saved_or(settings, FX_STYLE_KEY, FX_STYLE.into())
}

/// Effect art drawn from the idle thrower, so all three poses are the same character.
pub fn reference(folder: &str) -> Option<&'static str> {
    matches!(folder, "fx/thrower-toss" | "fx/thrower-throw").then_some("fx/thrower-idle")
}

/// Output size requested from OpenAI-style APIs.
pub fn size(folder: &str) -> &'static str {
    match folder {
        "fx/cloud" => "1536x1024",
        "fx/thrower-idle" | "fx/thrower-toss" | "fx/thrower-throw" => "1024x1536",
        _ => "1024x1024",
    }
}

/// The full prompt sent to the model (also what "copy prompt" copies).
pub fn full(settings: &Settings, folder: &str) -> String {
    if folder.starts_with("pet/") {
        return editable(settings, folder);
    }
    let preamble = if reference(folder).is_some() { FX_REFERENCE } else { "" };
    format!("{preamble}{} {}", editable(settings, folder), fx_style(settings))
}

#[derive(Serialize)]
pub struct PromptInfo {
    pub key: String,
    pub value: String,
    pub default: String,
}

/// Everything the generation page edits, keyed by folder, plus the shared effect style.
pub fn all(settings: &Settings) -> Vec<(String, PromptInfo)> {
    let mut out: Vec<(String, PromptInfo)> = POSES
        .iter()
        .chain(EFFECTS)
        .map(|(folder, _)| {
            (folder.to_string(), PromptInfo { key: key(folder), value: editable(settings, folder), default: default_for(folder) })
        })
        .collect();
    out.push(("fxStyle".into(), PromptInfo { key: FX_STYLE_KEY.into(), value: fx_style(settings), default: FX_STYLE.into() }));
    out
}

/// Setting keys carried by an exported config (resolved values, so defaults travel too).
pub fn exported_keys() -> Vec<String> {
    POSES.iter().chain(EFFECTS).map(|(f, _)| key(f)).chain([FX_STYLE_KEY.to_string()]).collect()
}
