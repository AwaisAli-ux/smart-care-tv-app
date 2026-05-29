# Smart Care TV — Viva & Project Defense Preparation Guide

Welcome to the **Smart Care TV** Viva Preparation Guide. This document contains a comprehensive breakdown of the project architecture, technologies used, file functionalities, and answers to critical technical questions commonly asked during project defense and oral examinations.

---

## 1. Project Overview & Architecture

**Smart Care TV** is a premium, high-performance IPTV streaming client built using **Flutter** and **Dart**. It is designed to consume Xtream Codes API server playlists to deliver **Live TV, Movies, and TV Series** in a visually rich, dark-themed user interface.

### Key Capabilities:
- **Responsive Layout**: Adapts between a Bottom Navigation layout for mobile phones and a Sidebar Navigation layout for Tablets and Smart TVs.
- **Native Player Integration**: Leverages `media_kit` (backed by `libmpv`/`FFmpeg`) to handle high-fidelity streams, resolving typical mobile audio codec limitations (e.g., muted Dolby Digital AC3/EAC3 audio).
- **TV Remote (D-Pad) Navigation**: Handles focus traps, visual focus rings, shadows, and D-pad key events to offer full TV remote control support.
- **Robust Connection Handler**: Implements connection health diagnostics, stream auto-retrying, and candidate URL fallbacks.
- **Optimized JSON Parsing**: Utilizes Dart background Isolates (`compute()`) to digest massive playlist payloads without lagging the UI thread.
- **Per-User Storage**: Isolates local configurations and favorite streams per account using encrypted/plain key namespaces in `shared_preferences`.

---

## 2. Core Technologies Used & Rationale

| Technology / Package | Category | Purpose & Rationale |
| :--- | :--- | :--- |
| **Flutter & Dart** | Core Framework | Enables compiling to native ARM/Intel code for Android, iOS, Android TV, macOS, Windows, and Web from a single codebase. |
| **Provider** | State Management | Organizes state changes reactively. Centralizes login, navigation, loaded categories/channels, loading flags, and favorites. |
| **media_kit** & **media_kit_video** | Video Engine | Employs native `libmpv` and `FFmpeg` decoders. Essential for decoding professional streaming formats like **HLS/M3U8, MPEG-TS, DASH**, and high-quality codecs (**HEVC/H.265, AC3, EAC3/Dolby Digital, DTS**). |
| **shared_preferences** | Local Storage | Persists authentication flags, user credentials, and favorites lists across app restarts. |
| **http** | Networking | Reuses connection handles via a persistent `http.Client` for fast REST calls to the IPTV billing server API. |
| **cached_network_image** | Image Loading | Downloads, caches, and automatically displays posters/icons, preventing excessive network traffic and improving offline capability. |
| **shimmer** | UI Animation | Implements a skeleton placeholder loading effect before network assets render. |
| **carousel_slider** & **smooth_page_indicator** | UI Components | Creates the premium auto-rotating Hero Banner carousel on the home screen. |

---

## 3. Directory & File Breakdown

The project follows a standard clean-architecture organization in the `lib/` directory:

```text
lib/
├── main.dart
├── models/
│   └── content_model.dart
├── theme/
│   └── app_theme.dart
├── services/
│   ├── app_state.dart
│   └── iptv_service.dart
├── widgets/
│   └── common_widgets.dart
└── screens/
    ├── splash_screen.dart
    ├── login_screen.dart
    ├── main_shell.dart
    ├── home_screen.dart
    ├── live_tv_screen.dart
    ├── movies_screen.dart
    ├── series_screen.dart
    ├── detail_screen.dart
    ├── search_screen.dart
    ├── favorites_screen.dart
    ├── settings_screen.dart
    └── more_screen.dart
```

### 3.1 Entry Point

#### `lib/main.dart`
- **Main Function**: Entry point of the Dart VM.
- **Key Responsibilities**:
  - Initializes Flutter bindings (`WidgetsFlutterBinding.ensureInitialized()`).
  - **CRITICAL**: Calls `MediaKit.ensureInitialized()` before any player is created. This registers the native `libmpv` dynamic library mappings.
  - Sets allowed orientations (portrait + landscape) and styles the system UI overlay (translucent status bar and color-matched navigation bar).
  - Wraps the entire application tree inside a `ChangeNotifierProvider` providing `AppState`.
  - Configures universal TV remote shortcuts, specifically mapping `LogicalKeyboardKey.select` to a standard Material `ActivateIntent`.
  - Launches `SplashScreen` as the initial view.

---

### 3.2 Data Models

#### `lib/models/content_model.dart`
- **Main Function**: Structures data contracts parsed from the Xtream Codes server.
- **Key Classes**:
  - `ContentType`: Enum containing `live`, `movie`, and `series`.
  - `ContentItem`: Representation of any streamable media. Stores metadata like titles, images, genres, ratings, EPG (now playing/next up), stream IDs, and video container extensions (`.mp4`, `.mkv`, `.ts`).
  - `EpisodeInfo`: Reps a TV Series episode. Maps properties like `seasonNum`, `episodeNum`, `streamId`, container format `ext`, plot summary, and `directSource` (when provided directly by the server API).
  - `SeasonInfo`: Contains a list of `EpisodeInfo` grouped under a `seasonNum`.

---

### 3.3 Services (Business Logic)

#### `lib/services/app_state.dart`
- **Main Function**: Manages globally accessible application state via ChangeNotifier.
- **Key Responsibilities**:
  - **Authentication**: Stores `isLoggedIn` flags, `username`, and `password`.
  - **Content Cache**: Holds in-memory lists of parsed `channels`, `movies`, and `series`.
  - **Favorites Scoping**: Manages favorite items in a local `Set<String>`. Saves and loads lists dynamically per-user (`favorites_$username`) to avoid list mixing between different user accounts.
  - **Navigation State**: Stores the active sidebar/bottom-bar navigation tab index.
  - **Featured Interleaving**: Implements `_buildFeaturedChannelList()`. This runs a diversification algorithm that scans raw channels for famous brand keywords (e.g., CNN, BBC, ESPN, HBO), pulls one representative channel per brand, places them at the top in an interleaved fashion, and appends the rest behind them.

#### `lib/services/iptv_service.dart`
- **Main Function**: Conducts networking requests and wraps Xtream API actions.
- **Key Features**:
  - **Compute Offloading**: Uses top-level helper functions `_parseJsonList` and `_parseJsonMap` in Dart `compute()` blocks. This runs the heavy parsing workload inside a background Thread (Isolate), preventing the main UI thread from dropping frames (stuttering).
  - **HTTP Optimization**: Reuses a persistent `http.Client` session and configures customized HTTP headers (User-Agent mimicking mobile/TV, compression headers) for maximum loading speed.
  - **Xtream Methods**:
    - `authenticate()`: Verifies credentials via `player_api.php?username=...&password=...`.
    - `getLiveChannels()`, `getMovies()`, `getSeries()`: Pulls streams matching corresponding Xtream actions.
    - `getSeriesInfo()` & `getAllEpisodes()`: Fetches deep information about a TV Series, extracts seasons, parses episode streams, sorts them numerically, and models them as lists of `SeasonInfo` / `EpisodeInfo`.
    - **Stream URL Builders**: Generates direct video streams:
      - Live TV: `/live/username/password/streamId.m3u8` (or `.ts` or extension-less).
      - Movie: `/movie/username/password/streamId.container_extension`.
      - TV Series: `/series/username/password/episodeStreamPath`.

---

### 3.4 Styling & UI Assets

#### `lib/theme/app_theme.dart`
- **Main Function**: Centralizes the visual styling guide of the application.
- **Key Color Tokens**:
  - `AppColors.bg`: Primary deep pitch-black/midnight canvas (`#06080F`).
  - `AppColors.bg2`: Elevated dark slate card/sidebar background (`#0C1018`).
  - `AppColors.accent`: Neon orange-red theme highlight (`#E8401C`).
  - `AppColors.border`: Subtle dark-blue border lines (`#1F2C42`).
  - `AppColors.live`: Distinct red signal color for live icons.
- **Theme Configurations**: Sets `useMaterial3: true`, wires in Google Fonts' **Inter** typography, customizes dark inputs with active colored borders, and shapes rounded buttons globally.

---

### 3.5 Reusable Components

#### `lib/widgets/common_widgets.dart`
- **Main Function**: Shared stateless/stateful visual building blocks.
- **Key Widgets**:
  - `_tvFocusWrapper()`: **CRITICAL for TV support**. Wraps any child in a dynamic `Focus` node. When the element gains focus via the TV D-pad, it draws a glowing neon orange border around it and attaches an outer shadow. It also intercepts logical keyboard OK/Select buttons to trigger tap functions.
  - `LiveBadge`: Pill widget with a white dot and red background signaling "LIVE" content.
  - `RatingBadge`: Displays IMDB/system ratings using a star vector and semi-transparent gold container.
  - `ChannelCard`: Render layout for TV stations. Shows logo or generates a alphabetical text avatar if image fails to load.
  - `MediaCard`: Poster-style card for Movies/Series featuring episode totals or release years.
  - `FilterChipsRow`: Horizontal slide selector for sorting categories.
  - `ContentGrid` & `ChannelGrid`: Responsive columns that scale columns automatically based on screen widths (supports phone vs. tablet sizing).

---

### 3.6 Screen Layouts

#### `lib/screens/splash_screen.dart`
- **Main Function**: First interactive screen; handles animated loading and auto-routing.
- **Key Features**:
  - Implements a Fade/Scale entry transition on the app logo using standard `AnimationController` and curved tweens.
  - Inspects `SharedPreferences` to determine user state.
  - **Auto-Login**: If user is logged in, it retrieves credentials, restores favorites, immediately pushes the user into `MainShell` to prevent loading blockages, and loads categories and streams in the background.
  - **Anti-Spam Loading**: Fetches data sequentially (Categories -> Channels -> Movies -> Series) to prevent triggering security anti-DDoS blocks on IPTV servers, updating state incrementally as blocks finish.

#### `lib/screens/login_screen.dart`
- **Main Function**: User verification wall.
- **Key Features**:
  - Responsive screen layout: Wide mode (TV/Tablet) shows login details side-by-side with a movie poster collage. Narrow mode (Mobile) displays stacked elements.
  - Obscures password field and features a visibility toggle.
  - Implements an **Auto-Retry Fail-Safe**: If `IptvService.authenticate()` fails due to transient connection drops, it automatically attempts a second call.
  - On authentication, commits credentials persistently to `SharedPreferences` and launches background content retrieval.

#### `lib/screens/main_shell.dart`
- **Main Function**: App navigation scaffold.
- **Key Features**:
  - **Responsive Layout**: Renders left `_SidebarNav` (7 tabs) on screens >= 600px, and bottom `_BottomNav` (5 tabs) on mobile phones.
  - **TV Keyboard Handlers**: Overrides default behaviors by hooking directly into `HardwareKeyboard.instance.addHandler()`.
  - **Focus Zone Separation**: Splits focus between sidebar and content zone. D-pad Up/Down navigates sidebar tabs. D-pad Enter/Select/Right switches focus onto the active screen's first focusable component. D-pad Left, Back, or Escape shifts focus back onto the navigation sidebar.
  - **Safe Exit Protocol**: Overrides Android Back button press with `PopScope`. If focused on content, it focuses back to the sidebar. Otherwise, it presents a styled confirm dialog asking the user before shutting down with `SystemNavigator.pop()`.

#### `lib/screens/home_screen.dart`
- **Main Function**: Landing dashboard of the application.
- **Key Features**:
  - **Hero Carousel**: Renders featured items using a custom banner with a dark gradient overlay. Features auto-scroll intervals (every 5 seconds) using a PageController.
  - Integrates "Watch Now" action buttons and "My List" toggles directly on the banner.
  - Renders horizontal listing rows for Live Channels, Latest Movies, Trending Movies, and Expanded Channels.

#### `lib/screens/search_screen.dart`
- **Main Function**: Global search engine.
- **Key Features**:
  - Offers category filters (All, Live TV, Movies).
  - Displays quick search chips (Popular searches like News, Sports, Action).
  - Performs local search filtering by scanning titles, categories, and descriptions.

#### `lib/screens/live_tv_screen.dart` / `movies_screen.dart` / `series_screen.dart`
- **Main Function**: Media libraries.
- **Key Features**:
  - Analyzes the dataset dynamically to build a list of unique categories.
  - Feeds categories into `FilterChipsRow` to let users filter the library dynamically.
  - Renders filtered content inside responsive media grids.

#### `lib/screens/detail_screen.dart`
- **Main Function**: The core player, video stream dispatcher, and detailed metadata card.
- **Key Features**:
  - **Native Media Kit Video Integration**: Hosts `Player` and `VideoController` inside a custom viewport.
  - **MethodChannel Integration**: Calls native Android `AudioManager` via MethodChannel (`com.example.mbapp/audio`) to request exclusive audio focus and set maximum device stream volumes before initializing.
  - **Multi-Format Candidate Evaluation**: IPTV servers offer multiple container extensions. This screen generates a priority candidate list (e.g. Live TV evaluates `.m3u8`, `.ts`, and raw directory formats; Series evaluates direct Xtream paths or `.mp4`, `.mkv`, `.ts` VOD endpoints) and tries each one sequentially until one successfully streams.
  - **Auto-Retry Routine**: If a stream crashes, it triggers a periodic timer, updates a visual banner count, waits 4 seconds, and attempts a restart.
  - **TV Overlay controls**: Renders playback timelines, time positions, play/pause states, and fullscreen toggle buttons. Auto-hides controls after 4 seconds of idle playing.
  - **EPG Schedule Renderer**: Live channels render current, next, and later EPG blocks.
  - **Interactive Seasons Picker**: Series items load seasons dynamically, displaying them in a Dropdown menu and listing episodes with custom progress badges.

#### `lib/screens/settings_screen.dart`
- **Main Function**: App preferences control.
- **Key Features**:
  - Left preferences navigator and right view area.
  - **Parental Controls**: Toggles PIN protection and filters adult content categories.
  - **Quality Preferences**: Sets resolution caps and switches hardware acceleration options.
  - **Diagnostics**: Checks app version, clears image caches, and triggers metadata updates.

#### `lib/screens/more_screen.dart`
- **Main Function**: Overflow screen for smaller devices.
- **Key Features**:
  - Lists secondary navigation paths.
  - **Secure Sign-out**: Deletes login keys from `SharedPreferences`, resets state, cleans temporary memory caches, and redirects back to `LoginScreen`.

---

## 4. Key Architectural Highlights (Common Viva Questions)

### Q1: Why did you use `media_kit` instead of the standard Flutter `video_player`?
**Answer**: 
Standard video player packages in Flutter rely on basic platform decoders (like Android's `MediaPlayer` or iOS's `AVPlayer`). These decoders lack native support for professional streaming protocols (such as raw MPEG-TS streams) and high-quality audio codecs like Dolby Digital (AC3/EAC3) and DTS. This causes premium channels to stream with video but **no audio**. 
`media_kit` integrates native **FFmpeg** and **libmpv** libraries directly into the project. This embeds all audio and video decoders directly into the application compile bundle, guaranteeing flawless streaming with sound on all devices.

### Q2: How did you prevent the main UI thread from freezing when fetching large channel lists?
**Answer**: 
IPTV accounts often contain tens of thousands of channels, movies, and series. Parsing a JSON string containing this many items consumes significant CPU cycles. If done on the main thread, the app UI would drop frames and freeze.
To prevent this, the project offloads parsing to background Dart **Isolates** using the `compute()` function:
```dart
final List<dynamic> data = await compute(_parseJsonList, response.body);
```
This spawns a separate worker thread to parse the JSON string into Dart Maps and Lists, returning the processed output to the main thread. This keeps the UI thread running smoothly at 60/120 FPS.

### Q3: How is TV Remote / Keyboard D-Pad navigation implemented in this project?
**Answer**: 
Standard mobile apps rely on touch gestures, but TVs use directional keys. We solved this in three ways:
1. **Focus Scopes**: In `main_shell.dart`, we wrap the content area in a `FocusScopeNode`. When a menu tab is selected, the app moves focus to the content area using `_contentFocusScopeNode.requestFocus()`. Focus then automatically moves to the first focusable widget on the active screen.
2. **TV Focus Wrapper**: In `common_widgets.dart`, we created `_tvFocusWrapper`. This wraps clickable items in a `Focus` widget. When focused, it highlights the item with a glowing neon border and shadow, and maps the TV Remote OK/Select key to tap actions.
3. **Hardware Key Interception**: We registered a listener on the hardware keyboard in the main screen shell to capture key events. This handles custom navigation rules, such as pressing D-pad Left, Back, or Escape to move focus back to the sidebar.
```dart
HardwareKeyboard.instance.addHandler(_handleKeyEvent);
```

### Q4: Why does the app fetch data sequentially during startup instead of concurrently?
**Answer**: 
If the app requested live channels, movies, series, and categories all at once, it would send 4 or 5 heavy concurrent requests to the IPTV server. Many IPTV providers implement strict anti-DDoS rate limits. Sending too many concurrent requests can trigger temporary IP bans.
To prevent this, the app uses a sequential fetching design:
1. Pre-load Categories.
2. Fetch Live Channels.
3. Fetch Movies.
4. Fetch Series.
Between each step, the app updates `AppState` so new content appears in the UI incrementally, rather than making the user wait for everything to load.

### Q5: How are favorites stored securely and isolated for different users?
**Answer**: 
To support multiple accounts on the same device without mixing favorites lists, the app uses username-scoped keys in local storage:
```dart
String _favKey(String username) => username.isNotEmpty ? 'favorites_$username' : 'favorites_guest';
```
When a user logs in, the app reads keys under `favorites_<username>`. When signing out, the app clears the in-memory favorites set but leaves the data on disk intact. When the user logs back in, their personalized list is restored.

---

### Q6: How does the video player handle weak network connections or broken streams?
**Answer**: 
The app implements a robust fail-safe mechanism in `detail_screen.dart`:
1. **Candidate Fallbacks**: The app generates several streaming URL formats (like `.m3u8`, `.ts`, and raw paths) and tries each one sequentially until a stream starts successfully.
2. **Auto-Retry State Machine**: If a running stream disconnects, the player catches the exception, updates the UI with an overlay banner, and starts a 4-second countdown timer. When the countdown completes, it automatically attempts to reconnect.

### Q7: Why didn't you use Firebase for user authentication, content storage, or favorites?
**Answer**: 
Firebase is a Backend-as-a-Service (BaaS) intended for custom databases and authentication schemas. We did not use Firebase for several key architectural reasons:
1. **Third-Party API Integration**: This app acts as a client for external IPTV providers via the Xtream Codes server. The Xtream server itself provides authentication, media streams, and content catalogs. Adding Firebase would introduce a redundant and unnecessary middle layer.
2. **Dynamic Data Scaling**: Storing thousands of streaming channels and EPG entries in Firebase Firestore would require massive sync tasks and generate expensive read/write queries. Fetching directly from the IPTV server is faster and free of charge.
3. **Local Storage Sufficiency**: Core user preferences and favorite channels are highly specific to the individual account and device. Persisting them locally via `shared_preferences` keeps the app simple, fast, and fully functional without requiring external database calls.

---

## 5. Quick Reference: Xtream Codes API Actions

For the viva, remember these core API endpoints used by our networking layer (`lib/services/iptv_service.dart`):

* **Authentication**: `baseUrl/player_api.php?username=YOUR_USER&password=YOUR_PASSWORD`
* **Get Live Channels**: `...&action=get_live_streams`
* **Get Movies (VOD)**: `...&action=get_vod_streams`
* **Get Series**: `...&action=get_series`
* **Get Series Info & Episodes**: `...&action=get_series_info&series_id=SERIES_ID`
* **Get Categories (Live/VOD/Series)**: `...&action=get_live_categories` / `get_vod_categories` / `get_series_categories`
