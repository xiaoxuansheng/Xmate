#pragma once
#include <string>

struct ScreenRecordingStartupData {
    int offsetX = 0, offsetY = 0, width = 0, height = 0;
    std::string outputPath;
    int framerate = 30;
    std::string ffmpegPath;
    int mode = 0;  // 0 = region, 1 = fullscreen
    std::string encoder = "libx264";
    int crf = 23;
    std::string audioSource = "none";
    std::string audioDeviceName;  // actual dshow device name
    bool autoStart = false;
    bool ok = false;
};

// Find ffmpeg.exe: check <exe_dir>/ffmpeg.exe first, then PATH.
std::string FindFFmpegPath();

// Parse --screenrecording command-line arguments into ScreenRecordingStartupData.
// Args: --sr-offset-x N --sr-offset-y N --sr-width N --sr-height N
//       --sr-output "<path>" --sr-framerate N --sr-mode 0|1
ScreenRecordingStartupData ParseScreenRecordingArgs(const wchar_t* commandLine);

// Serialize ScreenRecordingStartupData to JSON for Dart consumption.
std::string SrDataToJson(const ScreenRecordingStartupData& data);
