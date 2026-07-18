#include "screenrecording_channel.h"
#include <windows.h>
#include <shlwapi.h>
#include <algorithm>
#include <vector>

#pragma comment(lib, "shlwapi.lib")

// ── FindFFmpegPath ──────────────────────────────────────────────
// Check <exe_dir>/ffmpeg.exe first, then fall back to "ffmpeg.exe" on PATH.

std::string FindFFmpegPath() {
    WCHAR exePath[MAX_PATH] = {};
    GetModuleFileNameW(NULL, exePath, MAX_PATH);
    PathRemoveFileSpecW(exePath);  // remove xmate.exe

    std::wstring bundled = std::wstring(exePath) + L"\\ffmpeg.exe";
    if (GetFileAttributesW(bundled.c_str()) != INVALID_FILE_ATTRIBUTES) {
        char buf[MAX_PATH] = {};
        WideCharToMultiByte(CP_UTF8, 0, bundled.c_str(), -1,
                            buf, sizeof(buf), nullptr, nullptr);
        return buf;
    }
    return "ffmpeg.exe";  // fallback to PATH
}

// ── Parse WString Helpers ───────────────────────────────────────

static std::string WsToUtf8(const std::wstring& ws) {
    if (ws.empty()) return {};
    char buf[2048] = {};
    WideCharToMultiByte(CP_UTF8, 0, ws.c_str(), -1,
                        buf, sizeof(buf), nullptr, nullptr);
    return buf;
}

static int WsToInt(const std::wstring& ws) {
    if (ws.empty()) return 0;
    return _wtoi(ws.c_str());
}

// ── ParseScreenRecordingArgs ────────────────────────────────────

ScreenRecordingStartupData ParseScreenRecordingArgs(const wchar_t* commandLine) {
    ScreenRecordingStartupData data;

    if (!commandLine || !wcsstr(commandLine, L"--screenrecording")) {
        return data;
    }

    // Build a copy we can tokenise.
    std::wstring cmd(commandLine);
    std::vector<std::wstring> tokens;
    size_t i = 0;
    while (i < cmd.size()) {
        while (i < cmd.size() && cmd[i] == L' ') i++;
        if (i >= cmd.size()) break;
        if (cmd[i] == L'"') {
            i++;
            std::wstring tok;
            while (i < cmd.size() && cmd[i] != L'"') { tok += cmd[i]; i++; }
            if (i < cmd.size()) i++;  // skip closing quote
            tokens.push_back(tok);
        } else {
            std::wstring tok;
            while (i < cmd.size() && cmd[i] != L' ') { tok += cmd[i]; i++; }
            tokens.push_back(tok);
        }
    }

    for (size_t t = 0; t < tokens.size(); t++) {
        if (tokens[t] == L"--sr-offset-x" && t + 1 < tokens.size())
            data.offsetX = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-offset-y" && t + 1 < tokens.size())
            data.offsetY = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-width" && t + 1 < tokens.size())
            data.width = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-height" && t + 1 < tokens.size())
            data.height = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-output" && t + 1 < tokens.size())
            data.outputPath = WsToUtf8(tokens[++t]);
        else if (tokens[t] == L"--sr-framerate" && t + 1 < tokens.size())
            data.framerate = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-mode" && t + 1 < tokens.size())
            data.mode = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-ffmpeg-path" && t + 1 < tokens.size())
            data.ffmpegPath = WsToUtf8(tokens[++t]);
        else if (tokens[t] == L"--sr-encoder" && t + 1 < tokens.size())
            data.encoder = WsToUtf8(tokens[++t]);
        else if (tokens[t] == L"--sr-crf" && t + 1 < tokens.size())
            data.crf = WsToInt(tokens[++t]);
        else if (tokens[t] == L"--sr-audio" && t + 1 < tokens.size())
            data.audioSource = WsToUtf8(tokens[++t]);
        else if (tokens[t] == L"--sr-audio-device" && t + 1 < tokens.size())
            data.audioDeviceName = WsToUtf8(tokens[++t]);
        else if (tokens[t] == L"--sr-auto" && t + 1 < tokens.size())
            data.autoStart = (tokens[++t] == L"1");
    }

    // Only auto-detect if not explicitly passed via --sr-ffmpeg-path.
    if (data.ffmpegPath.empty()) {
        data.ffmpegPath = FindFFmpegPath();
    }
    data.ok = (data.width > 0 && data.height > 0 && !data.outputPath.empty());
    return data;
}

// ── JSON string escape helper ────────────────────────────────────

static std::string JsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '"':  out += "\\\""; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;
        }
    }
    return out;
}

// ── SrDataToJson ────────────────────────────────────────────────

std::string SrDataToJson(const ScreenRecordingStartupData& data) {
    std::string json;
    json.reserve(1024);
    json += "{\"offsetX\":";
    json += std::to_string(data.offsetX);
    json += ",\"offsetY\":";
    json += std::to_string(data.offsetY);
    json += ",\"width\":";
    json += std::to_string(data.width);
    json += ",\"height\":";
    json += std::to_string(data.height);
    json += ",\"outputPath\":\"";
    json += JsonEscape(data.outputPath);
    json += "\",\"framerate\":";
    json += std::to_string(data.framerate);
    json += ",\"ffmpegPath\":\"";
    json += JsonEscape(data.ffmpegPath);
    json += "\",\"mode\":";
    json += std::to_string(data.mode);
    json += ",\"encoder\":\"";
    json += JsonEscape(data.encoder);
    json += "\",\"crf\":";
    json += std::to_string(data.crf);
    json += ",\"audioSource\":\"";
    json += JsonEscape(data.audioSource);
    json += "\",\"audioDeviceName\":\"";
    json += JsonEscape(data.audioDeviceName);
    json += "\",\"autoStart\":";
    json += data.autoStart ? "true" : "false";
    json += "}";
    return json;
}
