use crate::settings::{tr, Settings};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use image::{imageops::FilterType, DynamicImage, ImageFormat, RgbaImage};
use serde_json::{json, Value};
use std::io::Cursor;
use std::time::Duration;

/// Provider settings captured up front, so no lock is held during a request.
#[derive(Clone)]
pub struct Client {
    gemini: bool,
    key: Option<String>,
    base: String,
    model: String,
    proxy: String,
    english: bool,
}

impl Client {
    pub fn from(settings: &Settings) -> Self {
        let gemini = settings.string("provider").as_deref() == Some("gemini");
        let (key_setting, env) = if gemini { ("geminiKey", "GEMINI_API_KEY") } else { ("apiKey", "OPENAI_API_KEY") };
        let saved = settings.string(key_setting).unwrap_or_default().trim().to_owned();
        let key = if saved.is_empty() { std::env::var(env).unwrap_or_default() } else { saved };
        Client {
            gemini,
            key: (!key.is_empty()).then_some(key),
            base: settings.string("apiBase").unwrap_or_default().trim().trim_end_matches('/').to_owned(),
            model: settings.string(if gemini { "geminiModel" } else { "imageModel" }).unwrap_or_default().trim().to_owned(),
            proxy: settings.string("proxy").unwrap_or_default().trim().to_owned(),
            english: settings.english(),
        }
    }

    pub fn has_key(&self) -> bool {
        self.key.is_some()
    }

    fn l(&self, zh: &str, en: &str) -> String {
        tr(self.english, zh, en)
    }

    /// Honors the proxy from settings; otherwise reqwest uses HTTPS_PROXY / the system proxy.
    fn http(&self) -> Result<reqwest::Client, String> {
        let mut builder = reqwest::Client::builder().timeout(Duration::from_secs(240));
        if !self.proxy.is_empty() {
            let url = if self.proxy.contains("://") { self.proxy.clone() } else { format!("http://{}", self.proxy) };
            builder = builder.proxy(reqwest::Proxy::all(url).map_err(|e| e.to_string())?);
        }
        builder.build().map_err(|e| e.to_string())
    }

    /// Image + prompt → image, or prompt alone → image when `source` is None. Returns PNG bytes.
    pub async fn edit(&self, source: Option<&DynamicImage>, prompt: &str, size: &str) -> Result<Vec<u8>, String> {
        let key = self.key.clone().ok_or_else(|| self.l("需要先在设置里配置 API Key", "Set an API key in Settings first"))?;
        let source_png = source.map(|img| png(&downscale(img, 1024))).transpose()?;
        let image = if self.gemini {
            // Gemini can't output transparency: ask for white and key it out locally.
            let prompt = prompt.replace("transparent background", "plain solid white background")
                + " Use a plain, solid pure white background.";
            remove_white_background(self.gemini_generate(&key, source_png, &prompt).await?)
        } else {
            self.openai(&key, source_png, prompt, size).await?
        };
        png(&image)
    }

    async fn send(&self, request: reqwest::RequestBuilder) -> Result<Value, String> {
        let response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status();
        let json: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            let message = json["error"]["message"].as_str().map(str::to_owned);
            return Err(message.unwrap_or_else(|| format!("HTTP {}", status.as_u16())));
        }
        Ok(json)
    }

    fn decode(&self, b64: Option<&str>) -> Result<DynamicImage, String> {
        let bytes = b64.and_then(|s| B64.decode(s).ok()).ok_or_else(|| self.l("返回结果无法解析", "Couldn't parse the response"))?;
        image::load_from_memory(&bytes).map_err(|_| self.l("返回结果无法解析", "Couldn't parse the response"))
    }

    // ---- OpenAI-compatible /images/edits and /images/generations ----

    async fn openai(&self, key: &str, source: Option<Vec<u8>>, prompt: &str, size: &str) -> Result<DynamicImage, String> {
        let http = self.http()?;
        let gpt_image = self.model.starts_with("gpt-image");
        let size = if gpt_image { size } else { "1024x1024" };
        let request = match source {
            Some(png) => {
                let mut form = reqwest::multipart::Form::new()
                    .text("model", self.model.clone())
                    .text("prompt", prompt.to_owned())
                    .text("size", size.to_owned());
                form = if gpt_image {
                    form.text("background", "transparent").text("quality", "medium")
                } else {
                    form.text("response_format", "b64_json")
                };
                let part = reqwest::multipart::Part::bytes(png).file_name("pet.png").mime_str("image/png").map_err(|e| e.to_string())?;
                http.post(format!("{}/images/edits", self.base)).bearer_auth(key).multipart(form.part("image", part))
            }
            None => {
                let mut payload = json!({ "model": self.model, "prompt": prompt, "n": 1, "size": size });
                if gpt_image {
                    payload["background"] = json!("transparent");
                    payload["quality"] = json!("medium");
                } else {
                    payload["response_format"] = json!("b64_json");
                }
                http.post(format!("{}/images/generations", self.base)).bearer_auth(key).json(&payload)
            }
        };
        let json = self.send(request).await?;
        self.decode(json["data"][0]["b64_json"].as_str())
    }

    // ---- Google Gemini generateContent (text or image in, image out) ----

    async fn gemini_generate(&self, key: &str, source: Option<Vec<u8>>, prompt: &str) -> Result<DynamicImage, String> {
        let mut parts = vec![json!({ "text": prompt })];
        if let Some(png) = source {
            parts.push(json!({ "inline_data": { "mime_type": "image/png", "data": B64.encode(png) } }));
        }
        let url = format!("https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent", self.model);
        let payload = json!({
            "contents": [{ "parts": parts }],
            "generationConfig": { "responseModalities": ["TEXT", "IMAGE"] },
        });
        let json = self.send(self.http()?.post(url).header("x-goog-api-key", key).json(&payload)).await?;
        let reply = json["candidates"][0]["content"]["parts"].as_array().cloned().unwrap_or_default();
        if let Some(inline) = reply.iter().find_map(|p| p.get("inlineData").or_else(|| p.get("inline_data"))) {
            return self.decode(inline["data"].as_str());
        }
        let text: String = reply.iter().filter_map(|p| p["text"].as_str()).collect();
        let mut message = self.l("模型没有返回图片", "The model returned no image");
        if !text.is_empty() {
            message += &self.l("：", ": ");
            message += &text.chars().take(80).collect::<String>();
        }
        Err(message)
    }
}

pub fn downscale(img: &DynamicImage, max_side: u32) -> DynamicImage {
    if img.width().max(img.height()) <= max_side {
        return img.clone();
    }
    img.resize(max_side, max_side, FilterType::Lanczos3)
}

pub fn png(img: &DynamicImage) -> Result<Vec<u8>, String> {
    let mut out = Cursor::new(Vec::new());
    img.write_to(&mut out, ImageFormat::Png).map_err(|e| e.to_string())?;
    Ok(out.into_inner())
}

/// Make the near-white background transparent by flood-filling from the borders, so white
/// areas inside the character are kept.
fn remove_white_background(img: DynamicImage) -> DynamicImage {
    let mut rgba: RgbaImage = img.to_rgba8();
    let (w, h) = rgba.dimensions();
    let (w, h) = (w as usize, h as usize);
    let mut visited = vec![false; w * h];
    let mut stack: Vec<usize> = Vec::new();
    for x in 0..w {
        stack.push(x);
        stack.push((h - 1) * w + x);
    }
    for y in 0..h {
        stack.push(y * w);
        stack.push(y * w + w - 1);
    }
    let raw = rgba.as_mut();
    while let Some(i) = stack.pop() {
        if visited[i] {
            continue;
        }
        let p = &raw[i * 4..i * 4 + 4];
        if p[0] <= 232 || p[1] <= 232 || p[2] <= 232 {
            continue;
        }
        visited[i] = true;
        raw[i * 4..i * 4 + 4].copy_from_slice(&[0, 0, 0, 0]);
        let (x, y) = (i % w, i / w);
        if x > 0 { stack.push(i - 1); }
        if x < w - 1 { stack.push(i + 1); }
        if y > 0 { stack.push(i - w); }
        if y < h - 1 { stack.push(i + w); }
    }
    DynamicImage::ImageRgba8(rgba)
}
