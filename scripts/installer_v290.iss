; XMate v2.9.0 Installer Script
; Stable release — text selection auto-fill, dictionary float removed, input sanitization

#define AppName "XMate"
#define AppVersion "2.9.0"
#define AppPublisher "XMate"
#define AppExeName "xmate.exe"
#define SourcePath "..\build\windows\x64\runner\Release"
#define OutputPath "..\installer"

[Setup]
AppId={{A8F1C9E2-4D5B-4A3C-9E2F-1B7D8A3C5E9F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir={#OutputPath}
OutputBaseFilename=XMate_Setup_v2.9.0
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName} {#AppVersion}
MinVersion=10.0.19041

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; ── Main executable ──
Source: "{#SourcePath}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\flutter_windows.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── Plugin DLLs ──
Source: "{#SourcePath}\audioplayers_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\flutter_inappwebview_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\fvp.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\hotkey_manager_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\screen_retriever_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\url_launcher_windows_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\window_manager_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── SQLite — dictionary plugin ──
Source: "{#SourcePath}\sqlite3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\sqlite3_flutter_libs_plugin.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── Video codec DLLs (fvp / mdk-sdk) ──
Source: "{#SourcePath}\mdk.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\mdk-braw.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\mdk-nvjp2k.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\mdk-r3d.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\ffmpeg-8.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourcePath}\libass.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── FFmpeg — screen recording ──
Source: "{#SourcePath}\ffmpeg.exe"; DestDir: "{app}"; Flags: ignoreversion

; ── PDF — pdfium ──
Source: "{#SourcePath}\pdfium.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── WebView2 ──
Source: "{#SourcePath}\WebView2Loader.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── ONNX Runtime ──
Source: "{#SourcePath}\onnxruntime.dll"; DestDir: "{app}"; Flags: ignoreversion

; ── 7za.exe — archive preview ──
Source: "{#SourcePath}\7za.exe"; DestDir: "{app}"; Flags: ignoreversion

; ── Data — includes bundled assets (dict/lemma.en.txt, etc.) ──
Source: "{#SourcePath}\data\flutter_assets\*"; DestDir: "{app}\data\flutter_assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourcePath}\data\icudtl.dat"; DestDir: "{app}\data"; Flags: ignoreversion
Source: "{#SourcePath}\data\app.so"; DestDir: "{app}\data"; Flags: ignoreversion

; ── OCR models (translate models excluded — downloaded on demand by translate_model_manager.py) ──
Source: "{#SourcePath}\models\PP-OCRv6_small_det.onnx"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\PP-OCRv6_small_rec.onnx"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\doc_orientation.onnx"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\text_unwarping.onnx"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\textline_orientation.onnx"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\ppocrv6_dict.txt"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\ppocrv6_rec_config.yml"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\config.json"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\gpt2_merges.txt"; DestDir: "{app}\models"; Flags: ignoreversion
Source: "{#SourcePath}\models\gpt2_vocab.json"; DestDir: "{app}\models"; Flags: ignoreversion

; ── LibreTranslate scripts ──
Source: "{#SourcePath}\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
