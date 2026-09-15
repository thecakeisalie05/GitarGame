#define main gitarGameLegacyMain
#include "main.cpp"
#undef main

// Alpha.4 runtime: keep the proven scanner/input/chart code from main.cpp, but
// replace timing and rendering with a corrected audio-clock mapping and a real
// perspective highway. This lets us iterate safely without destabilizing the
// alpha.3 crash fixes.

static double readChartOffsetSeconds(const fs::path& file) {
    std::ifstream in(file);
    if (!in) return 0.0;
    std::string section;
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '{' || line[0] == '}') continue;
        if (line.front() == '[' && line.back() == ']') {
            section = line.substr(1, line.size() - 2);
            continue;
        }
        if (section != "Song") continue;
        const auto p = line.find('=');
        if (p == std::string::npos) continue;
        if (lower(trim(line.substr(0, p))) != "offset") continue;
        try {
            return std::stod(unquote(line.substr(p + 1)));
        } catch (...) {
            return 0.0;
        }
    }
    return 0.0;
}

static double correctedSongTime(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
    if (s.stems.empty() || !s.song) return 0.0;

    // Audio playback is the master clock. .chart Offset and song.ini delay use
    // opposite sign conventions in the GuitarGame chart ecosystem:
    //   .chart Offset: higher moves the chart earlier relative to audio
    //   song.ini delay: higher moves notes later relative to audio
    // Our user audio_offset_ms follows Clone Hero calibration semantics:
    // positive values delay the notes, negative values advance them.
    const double audioSeconds = static_cast<double>(GetMusicTimePlayed(s.stems.front().music));
    return audioSeconds
        + chartOffsetSeconds
        - static_cast<double>(s.song->delayMs) / 1000.0
        - static_cast<double>(cfg.audioOffsetMs) / 1000.0;
}

static void logSongTiming(const Session& s, const Settings& cfg, double chartOffsetSeconds) {
#ifdef _WIN32
    if (!s.song) return;
    std::ostringstream out;
    out << "Timing map loaded: chart_offset_s=" << chartOffsetSeconds
        << " song_ini_delay_ms=" << s.song->delayMs
        << " user_audio_offset_ms=" << cfg.audioOffsetMs;
    ggdiag::log(out.str());
#else
    (void)s; (void)cfg; (void)chartOffsetSeconds;
#endif
}

static Color withAlpha(Color c, unsigned char a) {
    c.a = a;
    return c;
}

static void drawDisc3D(Vector3 center, float radius, float thickness, int sides, Color color) {
    DrawCylinder(center, radius, radius, thickness, sides, color);
}

static void drawHighway3D(const Session& s, const Settings& cfg, double now, uint8_t held,
                          double chartOffsetSeconds) {
    ClearBackground(cfg.background);

    const float sw = static_cast<float>(GetScreenWidth());
    const float sh = static_cast<float>(GetScreenHeight());
    const float aspectScale = std::clamp(sw / std::max(1.0f, sh), 1.0f, 2.4f);

    // Physical dimensions are deliberately tiny. Perspective projection gives
    // us the classic tapered highway without any expensive scene complexity.
    const float roadWidth = 7.4f;
    const float laneWidth = roadWidth / 5.0f;
    const float hitZ = 0.35f;
    const float farZ = 13.0f + 10.0f * ((cfg.highwayLength - 0.35f) / 0.60f);
    const double visibleSeconds = 2.45 / std::max(0.25f, cfg.highwaySpeed);

    Camera3D camera{};
    camera.position = {0.0f, 6.4f, -6.8f};
    camera.target = {0.0f, 0.15f, 6.4f};
    camera.up = {0.0f, 1.0f, 0.0f};
    camera.fovy = 44.0f + (aspectScale - 1.0f) * 2.0f;
    camera.projection = CAMERA_PERSPECTIVE;

    BeginMode3D(camera);

    const float left = -roadWidth * 0.5f;
    const float right = roadWidth * 0.5f;
    const float nearZ = -0.35f;

    // Highway surface: two triangles, slightly below the notes to avoid z-fighting.
    const float roadY = 0.0f;
    DrawTriangle3D({left, roadY, nearZ}, {right, roadY, farZ}, {right, roadY, nearZ}, cfg.highway);
    DrawTriangle3D({left, roadY, nearZ}, {left, roadY, farZ}, {right, roadY, farZ}, cfg.highway);

    // Lane separators and outer rails.
    for (int i = 0; i <= 5; ++i) {
        const float x = left + laneWidth * static_cast<float>(i);
        const Color line = (i == 0 || i == 5) ? withAlpha(RAYWHITE, 90) : withAlpha(RAYWHITE, 34);
        DrawLine3D({x, roadY + 0.018f, nearZ}, {x, roadY + 0.018f, farZ}, line);
    }

    // Mild horizontal depth guides make speed/perspective easier to read.
    for (int i = 1; i <= 9; ++i) {
        const float t = static_cast<float>(i) / 10.0f;
        const float z = hitZ + t * (farZ - hitZ);
        DrawLine3D({left, roadY + 0.012f, z}, {right, roadY + 0.012f, z}, withAlpha(RAYWHITE, 18));
    }

    // Sustains first so note heads naturally sit on top.
    for (const auto& n : s.chart.notes) {
        if (n.missed || n.sustain <= 0.03) continue;
        const double dt = n.time - now;
        if (dt > visibleSeconds * 1.06 || dt + n.sustain < -0.20) continue;

        const float z0 = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
        const float z1 = hitZ + static_cast<float>((dt + n.sustain) / visibleSeconds) * (farZ - hitZ);
        const float startZ = std::max(nearZ, z0);
        const float endZ = std::min(farZ, z1);
        if (endZ <= startZ) continue;

        for (int lane = 0; lane < 5; ++lane) {
            if (!(n.mask & (1 << lane))) continue;
            const float x = left + laneWidth * (static_cast<float>(lane) + 0.5f);
            Color c = cfg.lanes[lane];
            c.a = static_cast<unsigned char>(n.hit ? 65 : 155);
            DrawCube({x, 0.055f, (startZ + endZ) * 0.5f}, laneWidth * 0.16f, 0.045f,
                     std::max(0.02f, endZ - startZ), c);
        }
    }

    // Note heads.
    for (const auto& n : s.chart.notes) {
        if (n.missed) continue;
        const double dt = n.time - now;
        if (dt > visibleSeconds * 1.06 || dt < -0.22) continue;
        const float z = hitZ + static_cast<float>(dt / visibleSeconds) * (farZ - hitZ);
        if (z < nearZ || z > farZ) continue;

        for (int lane = 0; lane < 5; ++lane) {
            if (!(n.mask & (1 << lane))) continue;
            const float x = left + laneWidth * (static_cast<float>(lane) + 0.5f);
            Color c = cfg.lanes[lane];
            if (n.hit) c.a = 70;
            const float radius = laneWidth * 0.31f;
            drawDisc3D({x, 0.07f, z}, radius, 0.115f, 12, c);

            if (n.hopo || n.tap) {
                Color center = n.tap ? RAYWHITE : cfg.highway;
                center.a = n.hit ? 80 : 230;
                drawDisc3D({x, 0.185f, z}, radius * 0.43f, 0.025f, 12, center);
            }
        }
    }

    // Strike line and fret receptors.
    DrawCube({0.0f, 0.075f, hitZ}, roadWidth + 0.22f, 0.065f, 0.10f, cfg.hitLine);
    for (int lane = 0; lane < 5; ++lane) {
        const float x = left + laneWidth * (static_cast<float>(lane) + 0.5f);
        Color receptor = cfg.lanes[lane];
        receptor.a = (held & (1 << lane)) ? 255 : 75;
        drawDisc3D({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.29f, 0.12f, 14, receptor);
        DrawCylinderWires({x, 0.10f, hitZ - 0.12f}, laneWidth * 0.30f, laneWidth * 0.30f,
                          0.125f, 14, withAlpha(RAYWHITE, 155));
    }

    EndMode3D();

    // 2D HUD deliberately stays outside BeginMode3D so it remains crisp at any FPS/resolution.
    if (s.song) {
        DrawText(s.song->name.c_str(), 28, 24, 26, RAYWHITE);
        DrawText(s.song->artist.c_str(), 30, 54, 17, GRAY);
    }
    DrawText(TextFormat("Score %lld", s.score), 28, 92, 20, LIGHTGRAY);
    DrawText(TextFormat("Combo %d", s.combo), 28, 118, 20, LIGHTGRAY);
    const int judged = s.hits + s.misses;
    const float accuracy = judged > 0 ? 100.0f * static_cast<float>(s.hits) / static_cast<float>(judged) : 100.0f;
    DrawText(TextFormat("Accuracy %.2f%%", accuracy), 28, 144, 20, LIGHTGRAY);

    DrawText(TextFormat("Audio %.3fs", s.stems.empty() ? 0.0f : GetMusicTimePlayed(s.stems.front().music)),
             GetScreenWidth() - 220, 24, 17, GRAY);
    DrawText(TextFormat("Chart %.3fs", now), GetScreenWidth() - 220, 47, 17, GRAY);
    DrawText(TextFormat("chart Offset %+.1f ms | song delay %+.1f ms | calibration %+.1f ms",
                        chartOffsetSeconds * 1000.0,
                        s.song ? s.song->delayMs : 0.0f,
                        cfg.audioOffsetMs),
             28, 174, 16, GRAY);

    if (s.paused) drawCentered("PAUSED", GetScreenHeight() / 2 - 30, 44, RAYWHITE);
    DrawText("F7 earlier  F8 later  F9 reset calibration   Esc browser   R restart   Space pause",
             24, GetScreenHeight() - 28, 15, GRAY);
}

static void drawBrowserV4(const std::vector<SongInfo>& songs, int selected, const fs::path& root,
                          const Settings& cfg, const std::string& status) {
    ClearBackground(cfg.background);
    DrawText("GitarGame", 36, 26, 34, RAYWHITE);
    DrawText("minimal five-fret player  |  v0.1.0-alpha.4", 38, 66, 18, GRAY);
    const std::string rootText = root.string();
    DrawText(TextFormat("Songs: %s", rootText.c_str()), 38, 102, 18, LIGHTGRAY);

    if (songs.empty()) {
        drawCentered("No notes.chart files found.", 210, 28, RAYWHITE);
        drawCentered("Set songs_directory in config.ini, then press F5.", 255, 18, GRAY);
    } else {
        const int visible = std::max(5, (GetScreenHeight() - 210) / 34);
        const int maxStart = std::max(0, static_cast<int>(songs.size()) - visible);
        const int start = std::max(0, std::min(selected - visible / 2, maxStart));
        for (int row = 0; row < visible && start + row < static_cast<int>(songs.size()); ++row) {
            const int i = start + row;
            const int y = 145 + row * 34;
            if (i == selected) DrawRectangle(28, y - 4, GetScreenWidth() - 56, 30, Fade(RAYWHITE, 0.10f));
            const auto& song = songs[i];
            const std::string label = song.artist.empty() ? song.name : song.artist + "  -  " + song.name;
            DrawText(label.c_str(), 42, y, 21, i == selected ? RAYWHITE : LIGHTGRAY);
        }
    }

    if (!status.empty()) DrawText(status.c_str(), 38, GetScreenHeight() - 82, 18, ORANGE);
    DrawText("Up/Down select   Enter play   F3 bind guitar   F5 rescan   F6 reload config   F1 help",
             38, GetScreenHeight() - 42, 16, GRAY);
}

int main(int argc, char** argv) {
    SetTraceLogLevel(LOG_WARNING);
    const fs::path exeDir = fs::absolute(fs::path(argc > 0 ? argv[0] : "GitarGame.exe")).parent_path();
    const fs::path configPath = exeDir / "config.ini";

    Settings cfg;
    if (!loadConfig(configPath, cfg)) saveConfig(configPath, cfg);

    if (cfg.vsync) SetConfigFlags(FLAG_VSYNC_HINT | FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    else SetConfigFlags(FLAG_WINDOW_RESIZABLE | FLAG_MSAA_4X_HINT);
    InitWindow(cfg.windowWidth, cfg.windowHeight, "GitarGame");
    if (cfg.fullscreen) ToggleFullscreen();
    if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap);
    InitAudioDevice();
    SetMasterVolume(cfg.masterVolume);

#ifdef _WIN32
    XInputPoller poller(cfg.inputPollHz);
#endif

    fs::path songsRoot = fs::path(cfg.songsDirectory);
    if (songsRoot.is_relative()) songsRoot = exeDir / songsRoot;
    auto songs = scanSongs(songsRoot);
    int selected = 0;
    Session session;
    bool inBrowser = true;
    bool showHelp = false;
    bool showInput = false;
    bool binding = false;
    int bindIndex = 0;
    std::string status;
    double activeChartOffset = 0.0;

#ifdef _WIN32
    const std::vector<std::string> bindLabels = {"Green", "Red", "Yellow", "Blue", "Orange", "Strum Up", "Strum Down", "Star Power", "Start"};
    auto setBinding = [&](int index, WORD bit) {
        WORD* targets[] = {&cfg.green, &cfg.red, &cfg.yellow, &cfg.blue, &cfg.orange,
                          &cfg.strumUp, &cfg.strumDown, &cfg.starPower, &cfg.start};
        if (index >= 0 && index < static_cast<int>(std::size(targets))) *targets[index] = bit;
    };
#endif

    auto activateSongTiming = [&] {
        if (!session.song) { activeChartOffset = 0.0; return; }
        activeChartOffset = readChartOffsetSeconds(session.song->directory / "notes.chart");
        logSongTiming(session, cfg, activeChartOffset);
    };

    if (argc >= 2) {
        fs::path direct = argv[1];
        if (fs::is_regular_file(direct) && lower(direct.filename().string()) == "notes.chart") direct = direct.parent_path();
        if (fs::exists(direct / "notes.chart")) {
            SongInfo info = readSongInfo(direct);
            if (loadSong(session, info)) {
                inBrowser = false;
                activateSongTiming();
            } else status = session.error;
        }
    }

    while (!WindowShouldClose()) {
        if (IsKeyPressed(KEY_F1)) showHelp = !showHelp;
        if (IsKeyPressed(KEY_F2)) showInput = !showInput;

#ifdef _WIN32
        auto events = poller.takeEvents();
        if (IsKeyPressed(KEY_F3)) {
            binding = true;
            bindIndex = 0;
            if (!inBrowser && session.playing && !session.paused) togglePause(session);
        }
        if (binding) {
            if (IsKeyPressed(KEY_ESCAPE)) { binding = false; status = "Binding cancelled."; }
            for (const auto& ev : events) {
                if (!ev.down || !binding) continue;
                setBinding(bindIndex, ev.bit);
                ++bindIndex;
                if (bindIndex >= static_cast<int>(bindLabels.size())) {
                    binding = false;
                    saveConfig(configPath, cfg);
                    status = "Controller bindings saved to config.ini";
                }
            }
        }
#endif

        if (IsKeyPressed(KEY_F6)) {
            Settings updated = cfg;
            if (loadConfig(configPath, updated)) {
                cfg = updated;
                if (cfg.fpsCap > 0) SetTargetFPS(cfg.fpsCap); else SetTargetFPS(0);
                SetMasterVolume(cfg.masterVolume);
#ifdef _WIN32
                poller.restart(cfg.inputPollHz);
#endif
                fs::path newRoot = fs::path(cfg.songsDirectory);
                if (newRoot.is_relative()) newRoot = exeDir / newRoot;
                songsRoot = newRoot;
                songs = scanSongs(songsRoot);
                selected = std::clamp(selected, 0, std::max(0, static_cast<int>(songs.size()) - 1));
                status = "Reloaded config.ini";
                if (!inBrowser) logSongTiming(session, cfg, activeChartOffset);
            }
        }

        if (!inBrowser && !binding && !showHelp) {
            const float step = (IsKeyDown(KEY_LEFT_SHIFT) || IsKeyDown(KEY_RIGHT_SHIFT)) ? 25.0f : 5.0f;
            bool changedCalibration = false;
            if (IsKeyPressed(KEY_F7)) { cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs - step, -500.0f, 500.0f); changedCalibration = true; }
            if (IsKeyPressed(KEY_F8)) { cfg.audioOffsetMs = clampFloat(cfg.audioOffsetMs + step, -500.0f, 500.0f); changedCalibration = true; }
            if (IsKeyPressed(KEY_F9)) { cfg.audioOffsetMs = 0.0f; changedCalibration = true; }
            if (changedCalibration) {
                saveConfig(configPath, cfg);
                logSongTiming(session, cfg, activeChartOffset);
            }
        }

        if (!binding && !showHelp) {
            if (inBrowser) {
                if (IsKeyPressed(KEY_DOWN) && !songs.empty()) selected = (selected + 1) % static_cast<int>(songs.size());
                if (IsKeyPressed(KEY_UP) && !songs.empty()) selected = (selected - 1 + static_cast<int>(songs.size())) % static_cast<int>(songs.size());
                if (IsKeyPressed(KEY_F5)) {
                    songs = scanSongs(songsRoot);
                    selected = std::clamp(selected, 0, std::max(0, static_cast<int>(songs.size()) - 1));
                    status = "Song library rescanned.";
                }
                if (IsKeyPressed(KEY_ENTER) && !songs.empty()) {
                    if (loadSong(session, songs[selected])) {
                        inBrowser = false;
                        status.clear();
                        activateSongTiming();
                    } else status = session.error;
                }
            } else {
                for (auto& stem : session.stems) UpdateMusicStream(stem.music);
                const double now = correctedSongTime(session, cfg, activeChartOffset);
                const double window = cfg.hitWindowMs / 1000.0;
                advanceMisses(session, now, window);

#ifdef _WIN32
                const WORD xb = poller.buttons();
                const uint8_t gamepadHeld = heldMaskFromXInput(xb, cfg);
                for (const auto& ev : events) {
                    if (!ev.down) continue;
                    if (ev.bit == cfg.strumUp || ev.bit == cfg.strumDown)
                        tryHit(session, now, window, gamepadHeld, true);
                    uint8_t fretPressed = 0;
                    if (ev.bit == cfg.green) fretPressed = 1 << 0;
                    else if (ev.bit == cfg.red) fretPressed = 1 << 1;
                    else if (ev.bit == cfg.yellow) fretPressed = 1 << 2;
                    else if (ev.bit == cfg.blue) fretPressed = 1 << 3;
                    else if (ev.bit == cfg.orange) fretPressed = 1 << 4;
                    if (fretPressed) tryHit(session, now, window, gamepadHeld, false, fretPressed);
                }
#endif

                const uint8_t kbHeld = heldMaskFromKeyboard();
                if (IsKeyPressed(KEY_UP) || IsKeyPressed(KEY_DOWN)) tryHit(session, now, window, kbHeld, true);
                if (IsKeyPressed(KEY_A)) tryHit(session, now, window, kbHeld, false, 1 << 0);
                if (IsKeyPressed(KEY_S)) tryHit(session, now, window, kbHeld, false, 1 << 1);
                if (IsKeyPressed(KEY_J)) tryHit(session, now, window, kbHeld, false, 1 << 2);
                if (IsKeyPressed(KEY_K)) tryHit(session, now, window, kbHeld, false, 1 << 3);
                if (IsKeyPressed(KEY_L)) tryHit(session, now, window, kbHeld, false, 1 << 4);
                if (IsKeyPressed(KEY_R)) playFromStart(session);
                if (IsKeyPressed(KEY_SPACE)) togglePause(session);
                if (IsKeyPressed(KEY_ESCAPE)) {
                    unloadStems(session.stems);
                    session.playing = false;
                    session.song.reset();
                    activeChartOffset = 0.0;
                    inBrowser = true;
                }
            }
        }

        BeginDrawing();
        if (inBrowser) {
            drawBrowserV4(songs, selected, songsRoot, cfg, status);
        } else {
#ifdef _WIN32
            const uint8_t held = static_cast<uint8_t>(heldMaskFromKeyboard() | heldMaskFromXInput(poller.buttons(), cfg));
#else
            const uint8_t held = heldMaskFromKeyboard();
#endif
            drawHighway3D(session, cfg, correctedSongTime(session, cfg, activeChartOffset), held, activeChartOffset);
        }

#ifdef _WIN32
        if (showInput) {
            const int boxW = 420, boxH = 180;
            DrawRectangle(GetScreenWidth() - boxW - 18, 18, boxW, boxH, Fade(BLACK, 0.90f));
            DrawText("INPUT DIAGNOSTICS", GetScreenWidth() - boxW, 34, 18, RAYWHITE);
            DrawText(TextFormat("XInput: %s", poller.connected() ? "connected" : "not connected"),
                     GetScreenWidth() - boxW, 64, 17, poller.connected() ? GREEN : ORANGE);
            DrawText(TextFormat("Poll target: %d Hz", poller.hz()), GetScreenWidth() - boxW, 88, 17, LIGHTGRAY);
            const WORD b = poller.buttons();
            std::string pressed = "Held: ";
            for (const auto& [name, bit] : buttonNames()) if (b & bit) pressed += name + " ";
            DrawText(pressed.c_str(), GetScreenWidth() - boxW, 112, 16, LIGHTGRAY);
            DrawText("F3 runs binding wizard", GetScreenWidth() - boxW, 146, 16, GRAY);
        }
        if (binding) {
            const int w = std::min(620, GetScreenWidth() - 40), h = 210;
            const int x = (GetScreenWidth() - w) / 2, y = (GetScreenHeight() - h) / 2;
            DrawRectangle(x, y, w, h, Fade(BLACK, 0.96f));
            DrawRectangleLines(x, y, w, h, Fade(RAYWHITE, 0.45f));
            DrawText("Controller binding wizard", x + 24, y + 24, 26, RAYWHITE);
            DrawText(poller.connected() ? "XInput device detected" : "Waiting for XInput device...",
                     x + 24, y + 62, 17, poller.connected() ? GREEN : ORANGE);
            if (bindIndex < static_cast<int>(bindLabels.size())) {
                DrawText(TextFormat("Press: %s", bindLabels[bindIndex].c_str()), x + 24, y + 102, 30, RAYWHITE);
                DrawText(TextFormat("%d / %d", bindIndex + 1, static_cast<int>(bindLabels.size())), x + 24, y + 146, 17, GRAY);
            }
            DrawText("Esc cancels", x + w - 120, y + h - 32, 15, GRAY);
        }
#endif

        if (showHelp) {
            drawHelp(cfg);
            DrawText("Alpha.4: F7 earlier, F8 later, F9 reset timing calibration",
                     70, GetScreenHeight() / 2 + 165, 16, SKYBLUE);
        }
        DrawFPS(GetScreenWidth() - 92, GetScreenHeight() - 28);
        EndDrawing();
    }

    unloadStems(session.stems);
    CloseAudioDevice();
    CloseWindow();
    return 0;
}
