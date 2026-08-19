# Excerpt — Personal Research & Reference Archive
### Final Technical Architecture (MVP — Android)

---

## 1. Project Description

**Excerpt** একটা personal research/reference archiving app যেটার মূল লক্ষ্য — user যখন কোথাও কোনো text, image, বা screenshot দেখে যেটা পরে reference হিসেবে দরকার হতে পারে, সেটা **current workflow ভেঙে না দিয়ে** save করা।

সাধারণ note-taking app এ save করতে হলে user কে বর্তমান app ছেড়ে notes app এ যেতে হয়, paste/attach করতে হয়, organize করতে হয় — এই context-switch এর কারণে অনেক সময় information লস হয়ে যায় বা user save-ই করে না।

Excerpt এই সমস্যাটা solve করে দুইভাবে:

1. **Minimal-interaction capture** — clipboard copy বা image share থেকে সরাসরি, বর্তমান app এর উপরে ভেসে থাকা একটা lightweight overlay UI দিয়ে save করা যাবে, পুরোপুরি app switch ছাড়াই।
2. **Chat-based organization** — saved reference গুলো traditional note-card হিসেবে না দেখিয়ে, familiar messaging-app এর মতো conversation (chat/folder) হিসেবে দেখানো হবে। System থেকে save হওয়া content "received message" হিসেবে, আর user এর নিজের manual note/attachment "sent message" হিসেবে bubble আকারে show হবে।

MVP এ শুধু **text এবং image** capture নিয়ে কাজ হবে, ML classification ছাড়া (manual folder selection দিয়ে শুরু)। Future এ PDF capture, ML-based auto-classification, cloud sync, web app, এবং browser extension যোগ হবে।

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     ALWAYS-ON LAYER                          │
│   Foreground Service (persistent notification)               │
│   └── ClipboardManager.OnPrimaryClipChangedListener           │
└───────────────────────┬───────────────────────────────────────┘
                         │ clip changed event
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              FOCUS-BYPASS OVERLAY (invisible)                 │
│   1x1 transparent TYPE_APPLICATION_OVERLAY window              │
│   → app becomes "focused" momentarily                         │
│   → ClipboardManager.getPrimaryClip() now returns real data   │
│   → overlay immediately removed                                │
└───────────────────────┬───────────────────────────────────────┘
                         │ captured text
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                   SAVE NOTIFICATION                            │
│   "New text copied" + [Save] [Dismiss] actions                 │
└───────────┬─────────────────────────────────┬─────────────────┘
    [Dismiss]│                                 │[Save]
    discard  │                                 ▼
             │              ┌─────────────────────────────────┐
             │              │   FLOATING BOTTOM-SHEET OVERLAY   │
             │              │   (SYSTEM_ALERT_WINDOW, floats     │
             │              │    over current app, no task       │
             │              │    switch)                          │
             │              │  - folder/chat list (search)        │
             │              │  - "+ new folder" quick add          │
             │              │  - confirm → ✓ checkmark             │
             │              └───────────────┬───────────────────┘
             │                              ▼
             │              ┌─────────────────────────────────┐
             └─────────────▶│         LOCAL DATA LAYER          │
                             │   Room DB (offline-first)          │
                             │   - folders/chats table            │
                             │   - messages/references table       │
                             └───────────────┬───────────────────┘
                                             ▼
                             ┌─────────────────────────────────┐
                             │           CHAT UI LAYER            │
                             │  RecyclerView, left=received        │
                             │  (system-saved), right=sent          │
                             │  (user manual notes/attachments)     │
                             └─────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                  PARALLEL ENTRY: IMAGE CAPTURE                 │
│   Android Share Sheet (ACTION_SEND / ACTION_SEND_MULTIPLE)     │
│   user shares image → Excerpt appears in share menu             │
│   → same Floating Bottom-Sheet Overlay for folder select        │
│   → OCR (ML Kit Text Recognition) + Language ID runs             │
│   → saved to same Local Data Layer                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Core Modules

### 3.1 Clipboard Capture Module
- **Trigger:** `ClipboardManager.OnPrimaryClipChangedListener`, registered from a running Foreground Service.
- **Focus-bypass:** clip change detect হলে সাথে সাথে একটা 1x1px transparent `TYPE_APPLICATION_OVERLAY` window inflate করা হবে (requires `SYSTEM_ALERT_WINDOW` permission) → এই মুহূর্তে app "focused" গণ্য হয় → `getPrimaryClip()` কল করে real content read করা যাবে → overlay সাথে সাথে `removeView()` করে সরিয়ে ফেলা।
- **Duplicate-guard:** একই clip content দুইবার notification না দেখানোর জন্য last-captured hash রাখতে হবে।

### 3.2 Notification Module
- Persistent low-priority notification (Foreground Service এর জন্য বাধ্যতামূলক) + প্রতিটা নতুন clip এর জন্য একটা আলাদা actionable notification (`Save` / `Dismiss`).
- Notification নিজে শুধু trigger হিসেবে কাজ করবে — actual folder-selection UI notification এর ভিতরে না রেখে overlay bottom-sheet এ পাঠানো হবে (কারণ Android 12+ এ custom notification layout heavily restricted)।

### 3.3 Floating Bottom-Sheet Overlay Module
- `Save` চাপলে notification থেকে app খোলা হবে না — বরং একই `SYSTEM_ALERT_WINDOW` mechanism দিয়ে একটা bottom-sheet style floating view inflate হবে, current app এর উপরে ভেসে থাকবে।
- Contains: existing folder/chat list (searchable), "+ new folder" inline input, confirm button।
- Confirm করলে overlay বন্ধ হয়ে যাবে, data save হয়ে যাবে, ছোট্ট ✓ confirmation toast/animation দেখাবে।
- এই একই component reuse হবে image-share flow-এও।

### 3.4 Image Capture Module
- Manifest এ `ACTION_SEND` + `ACTION_SEND_MULTIPLE` intent-filter (mime type: `image/*`) — Android system share sheet এ Excerpt automatically list হবে।
- Selected হলে Floating Bottom-Sheet Overlay module reuse করে folder select করানো হবে।
- (Future: PDF এর জন্য একই intent-filter এ `application/pdf` যোগ করলেই হবে।)

### 3.5 OCR + Language Module
- ML Kit **Text Recognition (on-device)** দিয়ে image থেকে text extract।
- ML Kit **Language Identification (on-device)** দিয়ে extracted text এর language detect।
- সম্পূর্ণ offline-capable, network দরকার নেই।

### 3.6 Bengali Translation Module
- ML Kit **Translate (on-device model)** ব্যবহার করে original content preserve রেখে পাশে Bengali translation দেখানো।
- Bengali model availability/quality আলাদাভাবে verify করে নিতে হবে ML Kit এর supported-language list থেকে।

### 3.7 Local Data Layer
- **Room DB**, offline-first, দুইটা মূল entity:
  - `Folder` (id, name, created_at, user-defined/auto)
  - `Reference` (id, folder_id, type[text/image], content, ocr_text, detected_lang, translated_text, source_app(optional), timestamp)
- MVP এ কোনো ML classification নেই — folder selection পুরোপুরি manual, structure টা এমনভাবে বানানো যাতে future এ একটা `suggested_folder_id` column সহজে যোগ করা যায়।

### 3.8 Chat UI Layer
- `RecyclerView` + two message-bubble types:
  - **Received (left):** system-captured references (clipboard/share থেকে auto-saved)
  - **Sent (right):** user এর manual message/note/attachment, ভবিষ্যতে edit/reply/search করা যাবে
- প্রতিটা folder একটা আলাদা "chat conversation" হিসেবে দেখানো হবে।

---

## 4. Required Permissions & User Setup

| Permission / Setup | কেন দরকার |
|---|---|
| `SYSTEM_ALERT_WINDOW` (Display over other apps) | Clipboard focus-bypass overlay + floating bottom-sheet |
| Foreground Service + persistent notification | Continuous clipboard listening |
| Battery optimization exemption (ignore battery optimizations) | Aggressive OEM (MIUI/ColorOS/One UI) কে service kill করা থেকে আটকানো |
| OEM Autostart whitelist (manual, OEM-specific) | Reboot এর পরেও service auto-start হওয়ার জন্য |
| Notification permission (Android 13+) | Notification দেখানোর জন্য |

> **Fallback:** কিছু OEM এ উপরের সব দেওয়ার পরেও service kill হতে পারে — এক্ষেত্রে user app এ periodically (যেমন প্রতি কিছু ঘন্টায়) ঢুকে service কে alive রাখতে পারবে, এটা primary flow না, শুধু safety-net।

---

## 5. MVP Scope vs Future Roadmap

**MVP (এখন যা বানানো হবে):**
- Text capture (clipboard) + Image capture (share sheet)
- Overlay-based save flow (notification → bottom sheet → save)
- Manual folder/tag creation
- Chat-style UI
- On-device OCR + language detection
- Bengali translation (preserving original)
- Fully offline/local storage

**Future (MVP এর পরে):**
- ML-based auto category suggestion
- PDF capture support
- Cloud sync
- Web application
- Browser-based capture (extension)

---

## 6. Key Feasibility Notes (রেফারেন্সের জন্য)

- Android 10+ এ background/non-focused app clipboard read করতে পারে না — শুধু IME অথবা focused app পারে। তাই focus-bypass overlay trick বাধ্যতামূলক।
- Android 12+ এ fully custom notification layout নেই বললেই চলে (system template force করে), তাই folder-selection UI notification এর বদলে overlay bottom-sheet এ implement করা হচ্ছে।
- Android 15/16 এ `SYSTEM_ALERT_WINDOW` থাকা app background থেকে foreground service start করতে গেলে সেই মুহূর্তে visible overlay থাকা লাগে — আমাদের flow তে এমনিতেই overlay ব্যবহার হচ্ছে বলে এটা naturally align করে।
- Share-sheet ভিত্তিক image capture এ কোনো OS-level restriction নেই, এটা standard ও পুরোপুরি reliable।