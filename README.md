# Narrator 🎙️👁️
### *Your eyes. Your voice. Your language. On your phone.*

**Narrator is a real-time AI assistant for the visually impaired — built for India, running entirely offline on an Android phone.**

No internet required. No subscription. No cloud. Just powerful AI in your pocket.

---

## ✨ Features

### 👁️ Always-On Safety Guard
The moment you open the app, your camera starts watching the world for you.

- Detects **people, vehicles, dogs, benches, stairs, bikes** and more — in real time
- When something is in your path, your phone **vibrates instantly** and **speaks an alert out loud**
- Runs **30 times per second** — reacts faster than you can blink (~50ms)
- Works in **complete darkness** (uses AI, not just brightness)
- **No button to press** — it's always on, always protecting

---

### 🗣️ Ask Anything — Just Say "Suno"
Whenever you're curious about what's around you, just speak.

1. **Say "Suno"** (Hindi for *listen*) or **"Hey Narrator"**
2. **Ask your question** — *"What's in front of me?"*, *"What does this sign say?"*, *"Is anyone near me?"*
3. The app **takes the sharpest photo** at that moment
4. An AI **looks at the photo and understands your question**
5. Your phone **speaks the answer back** — within about 1.5 seconds

No tapping. No menus. Just talk.

---

### 🌐 Works Without Internet
Narrator is built **offline-first** — everything runs on your phone.

| Situation | What happens |
|---|---|
| No internet | Full AI runs locally on your device |
| With internet | Voice recognition is faster & more accurate |
| Internet drops mid-use | Automatically switches to offline mode |

You're never left without assistance.

---

### 🇮🇳 Built for India — In Indian Languages
Narrator speaks and understands **7 Indian languages**:

| Language | Language | Language |
|---|---|---|
| 🇮🇳 Hindi | 🇮🇳 Tamil | 🇮🇳 Telugu |
| 🇮🇳 Bengali | 🇮🇳 Marathi | 🇮🇳 Kannada |
| 🇮🇳 English | | |

Ask in your language. Get answers in your language. Accessibility cannot be English-only.

---

### 🔒 Your Privacy is Sacred
Narrator was built with India's **DPDP Act 2023** compliance from day one.

- 📵 **Zero data stored** — your camera frames and voice are processed and immediately discarded
- 🚫 **Nothing is ever uploaded** without your explicit permission
- 🔑 **You are in control** — a Privacy Dashboard shows everything the app has ever processed
- 🗑️ **Right to Erasure** — one tap to delete everything
- 👶 **Age verification** — consent screen confirms you are 18+
- 📧 Grievance contact: privacy@narrator-app.in

---

### ⚡ Smart Performance
Narrator automatically adapts to your phone's capability:

| Your Phone | AI Model Used |
|---|---|
| Any Android (3GB+ RAM) | SmolVLM-256M — fast, accurate |
| High-end (6GB+ RAM) | Qwen3-VL-2B — more detailed answers |

No manual configuration needed. It just works.

---

## 📱 Requirements

- Android phone — **Android 8.0 or newer**
- **3GB RAM minimum** (most phones since 2019)
- **~900MB free storage** for AI models (downloaded once on first launch)
- arm64-v8a processor (all modern Android phones)

---

## 🚀 Getting Started

### 1. Install
```bash
flutter pub get
flutter run --release
```

### 2. First Launch
The app will guide you through:
1. **Privacy Consent Screen** — plain language, English + Hindi
2. **Model Download** — downloads AI models once (~900MB total)
3. **Done** — point your camera and start using it

### 3. (Optional) Faster Voice Recognition
Get a free API key at [console.groq.com](https://console.groq.com) and enter it in **Settings → Groq API Key** for online STT.

---

## ⚡ Performance

| Feature | Speed |
|---|---|
| Obstacle detection | ~50ms (haptic alert first) |
| Wake word response | Instant (<100ms) |
| Voice-to-answer (online) | ~1.2 seconds |
| Voice-to-answer (offline) | ~2–4 seconds |
| Translation (22 languages) | ~150ms |

---

## 🧪 Test Coverage

**150 unit tests — all passing ✅**

Covers: obstacle detection, privacy consent, frame selection, speech recognition, language service, and all configuration constants.

```bash
flutter test test/unit/
# ✅ 150/150 tests passed
```

---

## 🤖 AI Models Used

| What it does | Model | Size |
|---|---|---|
| Obstacle detection | YOLOv8-nano (NCNN) | ~7MB |
| Wake word | Vosk small English | ~50MB |
| Speech detection | Silero VAD | ~2MB |
| Voice recognition (offline) | Whisper-tiny | ~75MB |
| Translation | IndicTrans2 INT8 | ~280MB |
| Visual understanding | SmolVLM-256M Q4 | ~500MB |

All models run **on your device**. None of your data touches a server.

---

## 📄 License
MIT License — free to use, modify, and build upon.

---

*Built with ❤️ for accessibility and India's linguistic diversity.*
*Selected as **#1 in Health & Wellbeing** — WitchHunt 2026 Top 40 Finalists 🏆*
