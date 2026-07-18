// XMate - WinRT OCR engine using Windows.Media.Ocr
//
// Uses the built-in Windows OCR API (available Win10 1803+) for English /
// Latin-script text recognition.  No extra models or dependencies needed.
//
// C++/WinRT headers are shipped with the Windows SDK (10.0.26100.0+).
// This file uses .get() on IAsyncOperation and does NOT need /await.
//
// THREADING: Windows.Media.Ocr MUST run on an MTA thread because calling
// .get() on IAsyncOperation from an STA thread triggers:
//   WINRT_ASSERT(!is_sta_thread())  — Windows.Foundation.h:5082
// The calling thread (Flutter platform thread) is STA via OleInitialize().
// We spawn a dedicated MTA worker thread, do all the WinRT work there,
// and join it — the caller blocks on std::thread::join(), not on the
// IAsyncOperation .get(), which avoids the assertion entirely.

#include "winrt_ocr_engine.h"

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

// C++/WinRT implementation headers (required for auto-returning functions)
#include <winrt/impl/Windows.Foundation.Collections.0.h>
#include <winrt/impl/Windows.Foundation.Collections.1.h>
#include <winrt/impl/Windows.Foundation.Collections.2.h>
#include <winrt/impl/Windows.Globalization.0.h>
#include <winrt/impl/Windows.Globalization.1.h>
#include <winrt/impl/Windows.Globalization.2.h>
#include <winrt/impl/Windows.Graphics.Imaging.0.h>
#include <winrt/impl/Windows.Graphics.Imaging.1.h>
#include <winrt/impl/Windows.Graphics.Imaging.2.h>
#include <winrt/impl/Windows.Media.Ocr.0.h>
#include <winrt/impl/Windows.Media.Ocr.1.h>
#include <winrt/impl/Windows.Media.Ocr.2.h>
#include <winrt/impl/Windows.Storage.Streams.0.h>
#include <winrt/impl/Windows.Storage.Streams.1.h>
#include <winrt/impl/Windows.Storage.Streams.2.h>

#include <algorithm>
#include <exception>
#include <sstream>
#include <string>
#include <thread>

namespace winrt_ocr {

using namespace winrt;
using namespace winrt::Windows::Globalization;
using namespace winrt::Windows::Graphics::Imaging;
using namespace winrt::Windows::Media::Ocr;
using namespace winrt::Windows::Storage::Streams;

// ── helpers ──────────────────────────────────────────────────────────────

/// Minimal JSON-string escape (no external JSON library dependency).
static std::string jsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b";  break;
      case '\f': out += "\\f";  break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (c < 0x20) {
          out += "\\u00";
          out += "0123456789abcdef"[c >> 4];
          out += "0123456789abcdef"[c & 0xf];
        } else {
          out += c;
        }
    }
  }
  return out;
}

/// Compute the axis-aligned bounding rect of a line from its words.
struct FloatRect { float x, y, w, h; };
static FloatRect lineBoundingRect(OcrLine const& line) {
  auto words = line.Words();
  uint32_t n = words.Size();
  if (n == 0) return {0, 0, 0, 0};
  auto first = words.GetAt(0).BoundingRect();
  float l = first.X, t = first.Y;
  float r = first.X + first.Width;
  float b = first.Y + first.Height;
  for (uint32_t i = 1; i < n; ++i) {
    auto wr = words.GetAt(i).BoundingRect();
    if (wr.X < l) l = wr.X;
    if (wr.Y < t) t = wr.Y;
    float rr = wr.X + wr.Width;
    float bb = wr.Y + wr.Height;
    if (rr > r) r = rr;
    if (bb > b) b = bb;
  }
  return {l, t, r - l, b - t};
}

/// Returns true if [c] is a CJK / wide character (should not have spaces
/// inserted around it — WinRT splits each CJK char as a separate word).
static bool isCjkOrWide(wchar_t c) {
  return (c >= 0x4E00 && c <= 0x9FFF)   // CJK Unified
      || (c >= 0x3400 && c <= 0x4DBF)   // CJK Ext A
      || (c >= 0x3040 && c <= 0x30FF)   // Hiragana + Katakana
      || (c >= 0xAC00 && c <= 0xD7AF)   // Hangul
      || (c >= 0xFF01 && c <= 0xFF60)   // fullwidth forms
      || (c >= 0x3000 && c <= 0x303F);  // CJK punctuation
}

/// Build a line's combined text by joining word texts.
/// Spaces are inserted only between Latin-script words — CJK characters
/// (which WinRT treats as one-word-per-char) stay unspaced.
static std::string lineText(OcrLine const& line) {
  auto words = line.Words();
  std::wstring w;
  for (uint32_t i = 0, n = words.Size(); i < n; ++i) {
    auto wordText = words.GetAt(i).Text();
    if (i > 0 && !w.empty() && !wordText.empty()) {
      wchar_t prevLast = w.back();
      wchar_t currFirst = wordText[0];
      // Only insert space if both sides are Latin (not CJK / wide).
      if (!isCjkOrWide(prevLast) && !isCjkOrWide(currFirst)) {
        w += L' ';
      }
    }
    w += wordText;
  }
  return winrt::to_string(w);
}

// ── Core OCR (runs on whichever thread calls it — must be MTA!) ─────────

/// Run the full WinRT OCR pipeline on the CURRENT thread.
/// PRECONDITION: current thread must be MTA (init_apartment already called).
/// [cropX]/[cropY] are added to all output coordinates for original-image space.
static std::string recognizeImpl(const std::vector<uint8_t>& pngBytes,
                                 int cropX, int cropY,
                                 const std::string& language) {
  try {
    // 1. Create an in-memory stream from the PNG bytes
    InMemoryRandomAccessStream stream;
    DataWriter writer(stream);
    writer.WriteBytes(pngBytes);
    writer.StoreAsync().get();   // commit
    writer.DetachStream();       // detach so we can seek
    stream.Seek(0);              // rewind for the decoder

    // 2. Decode PNG -> SoftwareBitmap
    auto decoder =
        BitmapDecoder::CreateAsync(BitmapDecoder::PngDecoderId(), stream)
            .get();
    auto frame = decoder.GetFrameAsync(0).get();
    SoftwareBitmap bitmap = frame.GetSoftwareBitmapAsync().get();

    // Convert to Bgra8 / Gray8 pixel format if needed
    if (bitmap.BitmapPixelFormat() != BitmapPixelFormat::Bgra8 &&
        bitmap.BitmapPixelFormat() != BitmapPixelFormat::Gray8) {
      bitmap = SoftwareBitmap::Convert(bitmap, BitmapPixelFormat::Bgra8);
    }

    // 3. Create OCR engine for the requested language
    Language langObj(winrt::to_hstring(language));
    OcrEngine engine = OcrEngine::TryCreateFromLanguage(langObj);
    if (!engine) {
      engine = OcrEngine::TryCreateFromUserProfileLanguages();
      if (!engine) {
        return R"({"ok":false,"error":"WinRT OCR: no language pack available. Install English language pack in Windows Settings."})";
      }
    }

    // 4. Recognise
    OcrResult ocrResult = engine.RecognizeAsync(bitmap).get();
    auto lines = ocrResult.Lines();
    uint32_t lineCount = lines.Size();

    // 5. Build JSON (matching the existing PP-OCRv6 output protocol)
    std::ostringstream json;
    json.precision(3);

    json << R"({"ok":true,"language":")" << language << "\",\"boxes\":[";

    for (uint32_t i = 0; i < lineCount; ++i) {
      if (i > 0) json << ',';
      auto line = lines.GetAt(i);
      std::string text = lineText(line);
      auto br = lineBoundingRect(line);
      float qx = br.x + cropX;
      float qy = br.y + cropY;
      json << R"({"text":")" << jsonEscape(text) << "\""
           << R"(,"score":1.0)"
           << R"(,"quad":[[)" << qx << ',' << qy << "],["
           << (qx + br.w) << ',' << qy << "],["
           << (qx + br.w) << ',' << (qy + br.h) << "],["
           << qx << ',' << (qy + br.h) << "]]}";
    }

    json << R"(],"fullText":")";
    for (uint32_t i = 0; i < lineCount; ++i) {
      if (i > 0) json << "\\n";
      json << jsonEscape(lineText(lines.GetAt(i)));
    }

    json << R"(","blocks":[)";
    for (uint32_t i = 0; i < lineCount; ++i) {
      if (i > 0) json << ',';
      auto line = lines.GetAt(i);
      std::string text = lineText(line);
      auto br = lineBoundingRect(line);
      json << R"({"text":")" << jsonEscape(text) << "\""
           << R"(,"x":)" << (br.x + cropX) << R"(,"y":)" << (br.y + cropY)
           << R"(,"w":)" << br.w << R"(,"h":)" << br.h << '}';
    }

    json << R"(],"diag":{"stage":"success","engine_src":"winrt"}})";

    return json.str();

  } catch (hresult_error const& e) {
    std::ostringstream err;
    err << R"({"ok":false,"error":"WinRT OCR: )"
        << jsonEscape(winrt::to_string(e.message()))
        << " (0x" << std::hex << e.code().value << ")\"}";
    return err.str();
  } catch (std::exception const& e) {
    std::ostringstream err;
    err << R"({"ok":false,"error":"WinRT OCR: )"
        << jsonEscape(e.what()) << R"("})";
    return err.str();
  }
}

}  // namespace winrt_ocr

// ── public entry point — spawns MTA thread to avoid STA assertion ────────

std::string WinRTOcrFromPNG(const std::vector<uint8_t>& pngBytes,
                            int cropX, int cropY,
                            const std::string& language) {
  // Windows.Media.Ocr cannot be called from an STA thread (Flutter's
  // platform thread is STA).  Spin up a dedicated MTA worker thread.
  // On a fresh thread with no COM initialized, winrt::init_apartment()
  // defaults to MTA — exactly what we need for the .get() calls.
  std::string result;
  std::exception_ptr ex;

  std::thread worker([&]() {
    try {
      winrt::init_apartment();
      result = winrt_ocr::recognizeImpl(pngBytes, cropX, cropY, language);
      winrt::uninit_apartment();
    } catch (...) {
      ex = std::current_exception();
    }
  });
  worker.join();

  if (ex) std::rethrow_exception(ex);
  return result;
}
