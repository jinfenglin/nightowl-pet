use crate::ai::Client;
use crate::library;
use crate::pet::{self, State};
use crate::prompts;
use crate::settings::tr;
use futures::future::join_all;
use image::DynamicImage;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

pub const VARIANTS: [&str; 3] = ["pet/low", "pet/hurt", "pet/dead"];

pub fn title(folder: &str, en: bool) -> String {
    let (zh, english) = match folder {
        "pet/normal" => ("满血", "Full HP"),
        "pet/low" => ("残血", "Low HP"),
        "pet/hurt" => ("受击", "Hit"),
        "pet/dead" => ("阵亡", "Knocked out"),
        "fx/cloud" => ("乌云", "Storm cloud"),
        "fx/thrower-idle" => ("小人 · 待机", "Thrower · idle"),
        "fx/thrower-toss" => ("小人 · 抛起", "Thrower · toss"),
        "fx/thrower-throw" => ("小人 · 投掷", "Thrower · throw"),
        "fx/can" => ("易拉罐", "Soda can"),
        "fx/hand" => ("巴掌", "Slapping hand"),
        _ => (folder, folder),
    };
    tr(en, zh, english)
}

/// Shows progress in the settings window and keeps two generations from overlapping.
struct Busy(AppHandle);

impl Busy {
    fn start(app: &AppHandle, text: &str) -> Option<Busy> {
        let s = app.state::<State>();
        let mut busy = s.busy.lock().unwrap();
        if busy.is_some() {
            return None;
        }
        *busy = Some(text.to_owned());
        drop(busy);
        pet::say(app, text, 600.0);
        pet::broadcast(app);
        Some(Busy(app.clone()))
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        *self.0.state::<State>().busy.lock().unwrap() = None;
        pet::broadcast(&self.0);
    }
}

struct Context {
    client: Client,
    root: PathBuf,
    en: bool,
}

fn context(app: &AppHandle) -> Context {
    let s = app.state::<State>();
    let settings = s.settings.lock().unwrap();
    Context { client: Client::from(&settings), root: s.library_root.clone(), en: settings.english() }
}

fn selected_image(app: &AppHandle, folder: &str) -> Option<DynamicImage> {
    let s = app.state::<State>();
    let path = library::selected(&s.library_root, &s.settings.lock().unwrap(), folder)?;
    image::open(path).ok()
}

/// Generate one slot, save it into the library and make it the current choice.
async fn generate_one(app: &AppHandle, ctx: &Context, folder: &str, source: Option<&DynamicImage>) -> Result<(), String> {
    let (prompt, size) = {
        let s = app.state::<State>();
        let settings = s.settings.lock().unwrap();
        (prompts::full(&settings, folder), prompts::size(folder))
    };
    let png = ctx.client.edit(source, &prompt, size).await?;
    let name = library::add_png(&ctx.root, folder, &png, None).ok_or_else(|| tr(ctx.en, "保存失败", "Couldn't save the image"))?;
    let s = app.state::<State>();
    library::select(&mut s.settings.lock().unwrap(), folder, Some(&name));
    pet::broadcast(app);
    Ok(())
}

/// Generate several slots in parallel; returns "title: error" for each failure.
async fn generate_many(app: &AppHandle, ctx: &Context, folders: &[&str], source: Option<&DynamicImage>) -> Vec<String> {
    let results = join_all(folders.iter().map(|f| generate_one(app, ctx, f, source))).await;
    folders
        .iter()
        .zip(results)
        .filter_map(|(f, r)| r.err().map(|e| format!("{}{}{e}", title(f, ctx.en), tr(ctx.en, "：", ": "))))
        .collect()
}

fn report(app: &AppHandle, en: bool, failures: &[String], done_zh: &str, done_en: &str, failed_zh: &str, failed_en: &str) {
    if failures.is_empty() {
        pet::say(app, &tr(en, done_zh, done_en), 6.0);
    } else {
        pet::say(app, &(tr(en, failed_zh, failed_en) + &failures.join(&tr(en, "；", "; "))), 12.0);
    }
}

/// Turn a photo into the full-HP character; with an API key, the other poses follow.
pub async fn create_character(app: AppHandle, photo: PathBuf) {
    let ctx = context(&app);
    let deselect_variants = || {
        let s = app.state::<State>();
        let mut settings = s.settings.lock().unwrap();
        for v in VARIANTS {
            library::select(&mut settings, v, None); // the old poses belong to the previous character
        }
    };
    if !ctx.client.has_key() {
        // No local cartoon filter on Windows: use the photo as it is.
        let s = app.state::<State>();
        if let Some(name) = library::import(&ctx.root, "pet/normal", &photo) {
            deselect_variants();
            library::select(&mut s.settings.lock().unwrap(), "pet/normal", Some(&name));
            pet::broadcast(&app);
        }
        pet::say(&app, &tr(ctx.en, "没配置 API Key，先直接用了这张照片。在「素材生成」页填好 Key 就能生成卡通形象",
            "No API key, so I'm using the photo as it is. Add a key on the Generate page to make a cartoon character"), 10.0);
        return;
    }
    let Ok(source) = image::open(&photo) else {
        pet::say(&app, &tr(ctx.en, "无法读取图片", "Couldn't read the image"), 6.0);
        return;
    };
    {
        let Some(_busy) = Busy::start(&app, &tr(ctx.en, "正在把照片变成卡通形象，稍等一下…", "Turning your photo into a cartoon, hang on…")) else { return };
        let prompt = prompts::full(&app.state::<State>().settings.lock().unwrap(), "pet/normal");
        let png = match ctx.client.edit(Some(&source), &prompt, "1024x1024").await {
            Ok(png) => png,
            Err(e) => {
                pet::say(&app, &(tr(ctx.en, "生成失败了… ", "Generation failed… ") + &e), 10.0);
                return;
            }
        };
        if let Some(name) = library::add_png(&ctx.root, "pet/normal", &png, None) {
            deselect_variants();
            library::select(&mut app.state::<State>().settings.lock().unwrap(), "pet/normal", Some(&name));
            pet::broadcast(&app);
        }
    }
    generate_poses(app, VARIANTS.iter().map(|s| s.to_string()).collect()).await;
}

/// Generate pose variants from the current full-HP image, in parallel.
pub async fn generate_poses(app: AppHandle, folders: Vec<String>) {
    let ctx = context(&app);
    let Some(base) = selected_image(&app, "pet/normal") else {
        pet::say(&app, &tr(ctx.en, "先选一张形象图片吧", "Pick a character image first"), 5.0);
        return;
    };
    if !ctx.client.has_key() {
        pet::say(&app, &tr(ctx.en, "生成状态图需要先在「素材生成」页配置 API Key（也可以在「形象」页手动导入）",
            "Generating poses needs an API key on the Generate page (or import images on the Appearance page)"), 8.0);
        return;
    }
    let names: Vec<String> = folders.iter().map(|f| title(f, ctx.en)).collect();
    let Some(_busy) = Busy::start(&app, &tr(ctx.en, &format!("正在生成 {} 状态图…", names.join(" / ")), &format!("Generating {}…", names.join(" / ")))) else { return };
    let list: Vec<&str> = folders.iter().map(String::as_str).collect();
    let failures = generate_many(&app, &ctx, &list, Some(&base)).await;
    report(&app, ctx.en, &failures, "状态图生成好了！试试攻击看看效果 😈", "Poses ready! Try an attack to see them 😈", "部分状态图生成失败 — ", "Some poses failed — ");
}

/// Effect art: independent assets in parallel; the thrower's toss / throw poses wait for the
/// idle pose (generated first if missing) so all three are the same character.
pub async fn generate_effects(app: AppHandle, folders: Vec<String>) {
    let ctx = context(&app);
    if !ctx.client.has_key() {
        pet::say(&app, &tr(ctx.en, "生成特效素材需要先配置 API Key（也可以复制提示词去网页版生成后导入）",
            "Generating effect art needs an API key (or copy the prompt to a web app and import the result)"), 8.0);
        return;
    }
    let names: Vec<String> = folders.iter().map(|f| title(f, ctx.en)).collect();
    let Some(_busy) = Busy::start(&app, &tr(ctx.en, &format!("正在生成特效素材：{}…", names.join(" / ")), &format!("Generating effect art: {}…", names.join(" / ")))) else { return };

    let posed: Vec<&str> = folders.iter().map(String::as_str).filter(|f| prompts::reference(f).is_some()).collect();
    let mut first: Vec<&str> = folders.iter().map(String::as_str).filter(|f| prompts::reference(f).is_none()).collect();
    let has_idle = selected_image(&app, "fx/thrower-idle").is_some();
    if !posed.is_empty() && !has_idle && !first.contains(&"fx/thrower-idle") {
        first.push("fx/thrower-idle");
    }
    let mut failures = generate_many(&app, &ctx, &first, None).await;
    if !posed.is_empty() {
        match selected_image(&app, "fx/thrower-idle") {
            Some(idle) => failures.extend(generate_many(&app, &ctx, &posed, Some(&idle)).await),
            None => failures.extend(posed.iter().map(|f| {
                format!("{}{}", title(f, ctx.en), tr(ctx.en, &format!("：需要先有「{}」", title("fx/thrower-idle", false)), &format!(": needs \u{201C}{}\u{201D} first", title("fx/thrower-idle", true))))
            })),
        }
    }
    report(&app, ctx.en, &failures, "特效素材生成好了！试一下攻击看看 ✨", "Effect art ready! Try an attack ✨", "部分素材生成失败 — ", "Some art failed — ");
}
