// XMate - PaddleOCR ONNX Runtime engine (UTF-8 BOM)
//
// PP-OCRv6 pipeline: doc-orientation → text-unwarping → det → textline-orientation → rec
//
// Replaced PP-OCRv5 cls.onnx scout-det approach with PP-OCRv6 standard modules.
// All three preprocessing modules are optional; the pipeline degrades gracefully
// when model files are missing.
//
// Input:  PNG bytes (via OcrFromPNG)
// Output: JSON  {"ok":true,"fullText":"...","language":"ch","diag":{...}}
//         or   {"ok":false,"error":"...","stage":"...","reason":"..."}
//

#include "onnx_ocr_engine.h"

#include <onnxruntime_cxx_api.h>

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>
#include <map>
#include <set>

#include "stb_image.h"
#include "gpt2_bpe_tokenizer.h"

#pragma comment(lib, "onnxruntime.lib")

// ── Debug printf disabled ─────────────────────────────────────────────────
#define DEBUG_PRINTF(...) do { } while(0)

// ============================================================================
// JSON helpers
// ============================================================================

static std::string esc(const std::string& s) {
    std::string r; r.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  r += "\\\""; break;
            case '\\': r += "\\\\"; break;
            case '\n': r += "\\n";  break;
            case '\r': r += "\\r";  break;
            case '\t': r += "\\t";  break;
            default:   r += c;
        }
    }
    return r;
}

// ============================================================================
// OCR text post-processing — restore word spacing for English
// ============================================================================

static inline bool _isLower(char c) { return c >= 'a' && c <= 'z'; }
static inline bool _isUpper(char c) { return c >= 'A' && c <= 'Z'; }
static inline bool _isAlpha(char c) { return _isLower(c) || _isUpper(c); }
static inline bool _isDigit(char c) { return c >= '0' && c <= '9'; }

/// Insert spaces at word boundaries in concatenated English text.
///
/// Rules (in priority order; only one fires per position):
///   A. CamelCase  : [a-z][A-Z] where the uppercase is followed by [a-z]
///   B. Acronym+Camel : [A-Z]{2..5}[A-Z][a-z] → split before the last upper
///   C1. digit→letter : [0-9][A-Za-z] → space
///   C2. letter→digit : [A-Za-z][0-9] → space
///
/// CJK / other non-ASCII bytes never trigger a split.  Existing spaces act
/// as natural breakers.  The function is idempotent.
static std::string InsertSpaces(const std::string& s) {
    const size_t n = s.size();
    if (n < 2) return s;

    std::string r;
    r.reserve(n + n / 6);

    r += s[0];

    for (size_t i = 1; i < n; i++) {
        char prev = s[i - 1];
        char curr = s[i];
        char next = (i + 1 < n) ? s[i + 1] : '\0';

        bool inserted = false;

        if (_isLower(prev) && _isUpper(curr) && _isLower(next)) {
            r += ' ';
            inserted = true;
        }

        if (!inserted && _isUpper(curr) && _isLower(next)) {
            int upperRun = 0;
            int jj = (int)i - 1;
            while (jj >= 0 && _isUpper(s[jj])) {
                upperRun++;
                jj--;
            }
            if (upperRun >= 2 && upperRun <= 5) {
                r += ' ';
                inserted = true;
            }
        }

        if (!inserted && _isDigit(prev) && _isAlpha(curr)) {
            r += ' ';
            inserted = true;
        }

        if (!inserted && _isAlpha(prev) && _isDigit(curr)) {
            r += ' ';
            inserted = true;
        }

        r += curr;
    }

    return r;
}

/// Apply GPT-2 vocabulary-based word boundary recovery to lowercase-only
/// letter runs.  Uses Viterbi DP dictionary segmentation.
///
/// Scans the string for contiguous runs of [a-z]+ with length >= 4.
/// For each run, segments it into known English words using DP and
/// inserts spaces at word boundaries using a graded strategy:
///   - n=2 words: split only if BOTH words are known
///   - n>=3 words: split only if BOTH sides of the boundary are known
///   - "a" and "i" are always treated as known (single-letter English words)
///
/// Returns the string with spaces inserted at word boundaries.
/// Non-[a-z] characters (spaces, digits, uppercase, CJK, punctuation) are
/// passed through unchanged and act as natural run separators.
static std::string ApplyBpeSegmentation(const std::string& s,
                                         const Gpt2BpeTokenizer& bpe) {
    if (s.size() < 3) return s;

    std::string result;
    result.reserve(s.size() + s.size() / 4);

    std::string run;  // current lowercase letter run
    auto flushRun = [&]() {
        if (run.empty()) return;
        if (run.size() < 3) {
            result += run;
        } else {
            auto words = bpe.segment(run);
            size_t n = words.size();
            if (n < 2) {
                result += run;
            } else {
                // Interleave words with spaces at known-word boundaries
                for (size_t i = 0; i < n; i++) {
                    if (i > 0) {
                        bool leftKnown = bpe.isKnown(words[i - 1]);
                        bool rightKnown = bpe.isKnown(words[i]);
                        bool insertSpace = false;
                        if (n == 2) {
                            // n=2: require BOTH sides known
                            insertSpace = leftKnown && rightKnown;
                        } else {
                            // n>=3: require BOTH sides known (conservative)
                            insertSpace = leftKnown && rightKnown;
                        }
                        if (insertSpace) result += ' ';
                    }
                    result += words[i];
                }
            }
        }
        run.clear();
    };

    for (size_t i = 0; i < s.size(); i++) {
        char c = s[i];
        if (c >= 'a' && c <= 'z') {
            run += c;
        } else if (c >= 'A' && c <= 'Z') {
            run += (char)(c + 32);  // tolower: "Shoeisa" -> run "shoeisa"
        } else {
            flushRun();
            result += c;
        }
    }
    flushRun();

    return result;
}

// ============================================================================
// TextBox struct
// ============================================================================

struct TextBox {
    std::vector<std::pair<float, float>> box; // 4 corner points [(x,y), ...]
    std::string text;
    float score = 0.0f;
};

// ============================================================================
// Image rotation helpers
// ============================================================================

/// Rotate an RGB image 180° in-place.
static void RotateImage180(std::vector<uint8_t>& rgb, int w, int h) {
    const size_t rowBytes = (size_t)w * 3;
    for (int y = 0; y < h / 2; y++) {
        uint8_t* top = rgb.data() + (size_t)y * rowBytes;
        uint8_t* bot = rgb.data() + (size_t)(h - 1 - y) * rowBytes;
        for (int x = 0; x < w; x++) {
            size_t off = (size_t)x * 3;
            size_t revX = (size_t)(w - 1 - x) * 3;
            std::swap(top[off + 0], bot[revX + 0]);
            std::swap(top[off + 1], bot[revX + 1]);
            std::swap(top[off + 2], bot[revX + 2]);
        }
    }
    if (h % 2 == 1) {
        uint8_t* mid = rgb.data() + (size_t)(h / 2) * rowBytes;
        for (int x = 0; x < w / 2; x++) {
            size_t offL = (size_t)x * 3;
            size_t offR = (size_t)(w - 1 - x) * 3;
            std::swap(mid[offL + 0], mid[offR + 0]);
            std::swap(mid[offL + 1], mid[offR + 1]);
            std::swap(mid[offL + 2], mid[offR + 2]);
        }
    }
}

/// Rotate an RGB image 90° clockwise.  Dimensions swap: (w,h) → (h,w).
/// Returns a new buffer; the caller should replace `rgb` and update w/h.
static std::vector<uint8_t> RotateImage90CW(const std::vector<uint8_t>& rgb, int w, int h) {
    std::vector<uint8_t> out((size_t)h * (size_t)w * 3);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int srcIdx = (y * w + x) * 3;
            int dstIdx = ((x) * h + (h - 1 - y)) * 3;
            out[dstIdx + 0] = rgb[srcIdx + 0];
            out[dstIdx + 1] = rgb[srcIdx + 1];
            out[dstIdx + 2] = rgb[srcIdx + 2];
        }
    }
    return out;
}

/// Rotate an RGB image 90° counter-clockwise.  Dimensions swap: (w,h) → (h,w).
static std::vector<uint8_t> RotateImage90CCW(const std::vector<uint8_t>& rgb, int w, int h) {
    std::vector<uint8_t> out((size_t)h * (size_t)w * 3);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int srcIdx = (y * w + x) * 3;
            int dstIdx = ((w - 1 - x) * h + y) * 3;
            out[dstIdx + 0] = rgb[srcIdx + 0];
            out[dstIdx + 1] = rgb[srcIdx + 1];
            out[dstIdx + 2] = rgb[srcIdx + 2];
        }
    }
    return out;
}

// ============================================================================
// Simple bilinear resize (no OpenCV dependency)
// ============================================================================

static uint8_t bilinearSample(const uint8_t* src, int sw, int sh, int c,
                               float x, float y, int channel) {
    if (x < 0.0f) x = 0.0f;
    if (y < 0.0f) y = 0.0f;
    if (x > (float)(sw - 1)) x = (float)(sw - 1);
    if (y > (float)(sh - 1)) y = (float)(sh - 1);
    int x0 = (int)x, y0 = (int)y;
    int x1 = (std::min)(x0 + 1, sw - 1);
    int y1 = (std::min)(y0 + 1, sh - 1);
    float dx = x - (float)x0, dy = y - (float)y0;

    float v00 = (float)src[(y0 * sw + x0) * c + channel];
    float v10 = (float)src[(y0 * sw + x1) * c + channel];
    float v01 = (float)src[(y1 * sw + x0) * c + channel];
    float v11 = (float)src[(y1 * sw + x1) * c + channel];

    float v = (1.0f - dx) * (1.0f - dy) * v00
            +        dx  * (1.0f - dy) * v10
            + (1.0f - dx) *        dy  * v01
            +        dx  *        dy  * v11;
    return (uint8_t)(v + 0.5f);
}

static void bilinearResize(const uint8_t* src, int sw, int sh, int c,
                            uint8_t* dst, int dw, int dh) {
    float sx = (float)(sw - 1) / (float)(std::max)(dw - 1, 1);
    float sy = (float)(sh - 1) / (float)(std::max)(dh - 1, 1);
    for (int y = 0; y < dh; y++) {
        float fy = (float)y * sy;
        for (int x = 0; x < dw; x++) {
            float fx = (float)x * sx;
            for (int ch = 0; ch < c; ch++) {
                dst[(y * dw + x) * c + ch] = bilinearSample(src, sw, sh, c, fx, fy, ch);
            }
        }
    }
}

// ============================================================================
// Perspective rectification & warp (no OpenCV dependency)
// ============================================================================

static void orderBoxCorners(const std::vector<std::pair<float, float>>& box,
                            float& x0, float& y0,
                            float& x1, float& y1,
                            float& x2, float& y2,
                            float& x3, float& y3)
{
    if (box.size() != 4) {
        x0 = box[0].first; y0 = box[0].second;
        x1 = box[1].first; y1 = box[1].second;
        x2 = box[2].first; y2 = box[2].second;
        x3 = box[3].first; y3 = box[3].second;
        return;
    }
    float sum[4], diff[4];
    for (int i = 0; i < 4; i++) {
        sum[i]  = box[i].first + box[i].second;
        diff[i] = box[i].first - box[i].second;
    }
    int tl = 0, tr = 0, br = 0, bl = 0;
    for (int i = 1; i < 4; i++) {
        if (sum[i] < sum[tl]) tl = i;
        if (sum[i] > sum[br]) br = i;
        if (diff[i] > diff[tr]) tr = i;
        if (diff[i] < diff[bl]) bl = i;
    }
    x0 = box[tl].first; y0 = box[tl].second;
    x1 = box[tr].first; y1 = box[tr].second;
    x2 = box[br].first; y2 = box[br].second;
    x3 = box[bl].first; y3 = box[bl].second;
}

static inline float ptDist(float x1, float y1, float x2, float y2) {
    float dx = x2 - x1, dy = y2 - y1;
    return std::sqrt(dx * dx + dy * dy);
}

static bool solve8x8(double A[8][8], double b[8], double x[8]) {
    double M[8][9];
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 8; j++) M[i][j] = A[i][j];
        M[i][8] = b[i];
    }
    for (int col = 0; col < 8; col++) {
        int bestRow = col;
        double bestVal = std::abs(M[col][col]);
        for (int row = col + 1; row < 8; row++) {
            if (std::abs(M[row][col]) > bestVal) {
                bestVal = std::abs(M[row][col]);
                bestRow = row;
            }
        }
        if (bestVal < 1e-12) return false;
        if (bestRow != col) {
            for (int j = 0; j < 9; j++) std::swap(M[col][j], M[bestRow][j]);
        }
        double pivot = M[col][col];
        for (int row = col + 1; row < 8; row++) {
            double factor = M[row][col] / pivot;
            if (factor == 0.0) continue;
            for (int j = col; j < 9; j++) M[row][j] -= factor * M[col][j];
        }
    }
    for (int i = 7; i >= 0; i--) {
        double sum = M[i][8];
        for (int j = i + 1; j < 8; j++) sum -= M[i][j] * x[j];
        x[i] = sum / M[i][i];
    }
    return true;
}

static bool computePerspective(
    float d0x, float d0y, float s0x, float s0y,
    float d1x, float d1y, float s1x, float s1y,
    float d2x, float d2y, float s2x, float s2y,
    float d3x, float d3y, float s3x, float s3y,
    double H[9])
{
    struct { float dx, dy, sx, sy; } c[4] = {
        {d0x, d0y, s0x, s0y}, {d1x, d1y, s1x, s1y},
        {d2x, d2y, s2x, s2y}, {d3x, d3y, s3x, s3y}
    };
    double A[8][8] = {};
    double b[8] = {};
    for (int i = 0; i < 4; i++) {
        float dx = c[i].dx, dy = c[i].dy, sx = c[i].sx, sy = c[i].sy;
        A[2*i][0] = dx;  A[2*i][1] = dy;  A[2*i][2] = 1.0;
        A[2*i][6] = -dx * sx;  A[2*i][7] = -dy * sx;
        b[2*i] = sx;
        A[2*i+1][3] = dx;  A[2*i+1][4] = dy;  A[2*i+1][5] = 1.0;
        A[2*i+1][6] = -dx * sy;  A[2*i+1][7] = -dy * sy;
        b[2*i+1] = sy;
    }
    double x[8];
    if (!solve8x8(A, b, x)) return false;
    for (int i = 0; i < 8; i++) H[i] = x[i];
    H[8] = 1.0;
    return true;
}

static std::vector<uint8_t> warpPerspective(
    const uint8_t* src, int srcW, int srcH,
    int dstW, int dstH, const double H[9])
{
    std::vector<uint8_t> out(dstW * dstH * 3, 0);
    for (int y = 0; y < dstH; y++) {
        for (int x = 0; x < dstW; x++) {
            double denom = H[6] * (double)x + H[7] * (double)y + H[8];
            if (std::abs(denom) < 1e-9) continue;
            double sx = (H[0] * (double)x + H[1] * (double)y + H[2]) / denom;
            double sy = (H[3] * (double)x + H[4] * (double)y + H[5]) / denom;
            for (int c = 0; c < 3; c++) {
                float v = bilinearSample(src, srcW, srcH, 3, (float)sx, (float)sy, c);
                out[(y * dstW + x) * 3 + c] = (uint8_t)(std::max(0.0f, std::min(255.0f, v)));
            }
        }
    }
    return out;
}

// ============================================================================
// Two-pass connected components labeling (for DB postprocessing)
// ============================================================================

class UnionFind {
public:
    std::vector<int> parent;
    UnionFind(int n) : parent(n) { for (int i = 0; i < n; i++) parent[i] = i; }
    int find(int x) {
        while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
        return x;
    }
    void unite(int a, int b) { parent[find(a)] = find(b); }
};

static std::vector<std::vector<std::pair<int,int>>>
connectedComponents(const uint8_t* mask, int w, int h, int minArea = 10) {
    std::vector<int> labels(w * h, 0);
    UnionFind uf(w * h);
    int nextLabel = 1;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int idx = y * w + x;
            if (!mask[idx]) continue;
            int left  = (x > 0 && mask[idx - 1])      ? labels[idx - 1]      : 0;
            int tl    = (x > 0 && y > 0 && mask[idx - w - 1]) ? labels[idx - w - 1] : 0;
            int top   = (y > 0 && mask[idx - w])      ? labels[idx - w]      : 0;
            int tr    = (x < w - 1 && y > 0 && mask[idx - w + 1]) ? labels[idx - w + 1] : 0;

            int minL = std::max({left, tl, top, tr});
            if (minL == 0) {
                labels[idx] = nextLabel++;
            } else {
                labels[idx] = minL;
                if (left && left != minL) uf.unite(left, minL);
                if (tl   && tl   != minL) uf.unite(tl,   minL);
                if (top  && top  != minL) uf.unite(top,  minL);
                if (tr   && tr   != minL) uf.unite(tr,   minL);
            }
        }
    }

    for (int i = 0; i < w * h; i++) {
        if (labels[i]) labels[i] = uf.find(labels[i]);
    }

    std::map<int, std::vector<std::pair<int,int>>> comps;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int lbl = labels[y * w + x];
            if (lbl) comps[lbl].push_back({x, y});
        }
    }

    std::vector<std::vector<std::pair<int,int>>> result;
    for (auto& kv : comps) {
        if ((int)kv.second.size() >= minArea) {
            result.push_back(std::move(kv.second));
        }
    }
    return result;
}

// ============================================================================
// OnnxOcrEngine — PP-OCRv6 pipeline
// ============================================================================

class OnnxOcrEngine {
public:
    ~OnnxOcrEngine() { /* Ort objects auto-cleanup */ }

    bool Initialize(const std::string& modelDir) {
        try {
            env_ = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "XMateOCR");

            Ort::SessionOptions opts;
            opts.SetIntraOpNumThreads(2);
            opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);

            // --- Load detection model (PP-OCRv6_small_det) ---
            {
                std::string path = modelDir + "/PP-OCRv6_small_det.onnx";
                std::ifstream f(path, std::ios::binary);
                if (!f.good()) {
                    lastError_ = "Detection model not found: PP-OCRv6_small_det.onnx";
                    return false;
                }
                f.close();
                std::wstring pathW(path.begin(), path.end());
                detSession_ = std::make_unique<Ort::Session>(*env_, pathW.c_str(), opts);
                auto detInName = detSession_->GetInputNameAllocated(0, allocator_);
                detInputName_ = std::string(detInName.get());
                auto detOutName = detSession_->GetOutputNameAllocated(0, allocator_);
                detOutputName_ = std::string(detOutName.get());
                detModelName_ = "PP-OCRv6_small_det.onnx";
                printf("[OCR init] det model loaded: PP-OCRv6_small_det.onnx\n");
            }

            // --- Load recognition model (PP-OCRv6_small_rec) ---
            {
                std::string path = modelDir + "/PP-OCRv6_small_rec.onnx";
                std::ifstream f(path, std::ios::binary);
                if (!f.good()) {
                    lastError_ = "Recognition model not found: PP-OCRv6_small_rec.onnx";
                    return false;
                }
                f.close();
                std::wstring pathW(path.begin(), path.end());
                recSession_ = std::make_unique<Ort::Session>(*env_, pathW.c_str(), opts);
                auto recInName = recSession_->GetInputNameAllocated(0, allocator_);
                recInputName_ = std::string(recInName.get());
                auto recOutName = recSession_->GetOutputNameAllocated(0, allocator_);
                recOutputName_ = std::string(recOutName.get());
                recModelName_ = "PP-OCRv6_small_rec.onnx";
                printf("[OCR init] rec model loaded: PP-OCRv6_small_rec.onnx\n");
            }

            // --- Load document orientation classifier (optional) ---
            {
                const char* docOriCandidates[] = {
                    "doc_orientation.onnx",
                    "PP-LCNet_x1_0_doc_ori_infer.onnx"
                };
                for (const char* fname : docOriCandidates) {
                    std::string path = modelDir + "/" + fname;
                    std::ifstream f(path, std::ios::binary);
                    if (f.good()) {
                        f.close();
                        std::wstring pathW(path.begin(), path.end());
                        docOriSession_ = std::make_unique<Ort::Session>(*env_, pathW.c_str(), opts);
                        auto inName = docOriSession_->GetInputNameAllocated(0, allocator_);
                        docOriInputName_ = std::string(inName.get());
                        auto outName = docOriSession_->GetOutputNameAllocated(0, allocator_);
                        docOriOutputName_ = std::string(outName.get());
                        docOriAvailable_ = true;
                        printf("[OCR init] doc_orientation model loaded: %s\n", fname);
                        break;
                    }
                }
                if (!docOriAvailable_) {
                    printf("[OCR init] doc_orientation model not found — disabled\n");
                }
            }

            // --- Load text unwarping model (optional, UVDoc) ---
            {
                const char* unwarpCandidates[] = {
                    "text_unwarping.onnx",
                    "UVDoc_infer.onnx"
                };
                for (const char* fname : unwarpCandidates) {
                    std::string path = modelDir + "/" + fname;
                    std::ifstream f(path, std::ios::binary);
                    if (f.good()) {
                        f.close();
                        std::wstring pathW(path.begin(), path.end());
                        unwarpSession_ = std::make_unique<Ort::Session>(*env_, pathW.c_str(), opts);
                        auto inName = unwarpSession_->GetInputNameAllocated(0, allocator_);
                        unwarpInputName_ = std::string(inName.get());
                        auto outName = unwarpSession_->GetOutputNameAllocated(0, allocator_);
                        unwarpOutputName_ = std::string(outName.get());
                        unwarpAvailable_ = true;
                        printf("[OCR init] text_unwarping model loaded: %s\n", fname);
                        break;
                    }
                }
                if (!unwarpAvailable_) {
                    printf("[OCR init] text_unwarping model not found — disabled\n");
                }
            }

            // --- Load text line orientation classifier (optional) ---
            {
                const char* textlineOriCandidates[] = {
                    "textline_orientation.onnx",
                    "PP-LCNet_x1_0_textline_ori_infer.onnx"
                };
                for (const char* fname : textlineOriCandidates) {
                    std::string path = modelDir + "/" + fname;
                    std::ifstream f(path, std::ios::binary);
                    if (f.good()) {
                        f.close();
                        std::wstring pathW(path.begin(), path.end());
                        textlineOriSession_ = std::make_unique<Ort::Session>(*env_, pathW.c_str(), opts);
                        auto inName = textlineOriSession_->GetInputNameAllocated(0, allocator_);
                        textlineOriInputName_ = std::string(inName.get());
                        auto outName = textlineOriSession_->GetOutputNameAllocated(0, allocator_);
                        textlineOriOutputName_ = std::string(outName.get());
                        textlineOriAvailable_ = true;
                        printf("[OCR init] textline_orientation model loaded: %s\n", fname);
                        break;
                    }
                }
                if (!textlineOriAvailable_) {
                    printf("[OCR init] textline_orientation model not found — disabled\n");
                }
            }

            // --- Load dictionary (ppocrv6_dict.txt) ---
            {
                std::string dictPath = modelDir + "/ppocrv6_dict.txt";
                std::ifstream dictFile(dictPath, std::ios::binary);
                if (!dictFile.is_open()) {
                    lastError_ = "Dictionary not found: ppocrv6_dict.txt";
                    return false;
                }

                std::string raw((std::istreambuf_iterator<char>(dictFile)),
                                std::istreambuf_iterator<char>());
                dictFile.close();

                const char* p = raw.data();
                size_t len = raw.size();
                if (len >= 3 && (unsigned char)p[0] == 0xEF
                             && (unsigned char)p[1] == 0xBB
                             && (unsigned char)p[2] == 0xBF) {
                    p += 3; len -= 3;
                }

                std::istringstream iss(std::string(p, len));
                std::string line;
                keys_.clear();
                while (std::getline(iss, line)) {
                    while (!line.empty() && line.back() == '\r') line.pop_back();
                    if (!line.empty()) keys_.push_back(line);
                }
                if (!keys_.empty()) {
                    dictName_ = "ppocrv6_dict.txt";
                    printf("[OCR init] dictionary loaded: ppocrv6_dict.txt (%zu chars)\n", keys_.size());
                } else {
                    lastError_ = "Dictionary ppocrv6_dict.txt is empty or unreadable.";
                    return false;
                }
            }

            // --- Load GPT-2 BPE tokenizer (optional, for word boundary recovery) ---
            {
                Gpt2BpeTokenizer bpe;
                if (bpe.Load(modelDir)) {
                    bpeTokenizer_ = std::make_unique<Gpt2BpeTokenizer>(std::move(bpe));
                    bpeAvailable_ = true;
                    printf("[OCR init] GPT-2 BPE tokenizer loaded OK\n");
                } else {
                    printf("[OCR init] GPT-2 BPE tokenizer not available: %s\n",
                           bpe.GetLastError().c_str());
                }
            }

            initialized_ = true;
            modelDir_ = modelDir;
            return true;

        } catch (const Ort::Exception& e) {
            lastError_ = std::string("ONNX init error: ") + e.what();
            return false;
        } catch (const std::exception& e) {
            lastError_ = std::string("Init error: ") + e.what();
            return false;
        }
    }

    bool IsInitialized() const { return initialized_; }
    std::string GetLastError() const { return lastError_; }

    // ═══════════════════════════════════════════════════════════════════════
    // PP-OCRv6 pipeline:
    //   decode → doc_orientation → text_unwarping → det → textline_orientation → rec → JSON
    // ═══════════════════════════════════════════════════════════════════════
    std::string Recognize(const std::vector<uint8_t>& pngBytes,
                          int cropOffsetX, int cropOffsetY, bool enableUnwarp) {
        if (!initialized_) {
            std::ostringstream j;
            j << "{\"ok\":false,\"error\":\"not_init\",\"stage\":\"init\""
              << ",\"reason\":\"" << esc(lastError_) << "\""
              << ",\"input\":{\"crop_offset\":[" << cropOffsetX << "," << cropOffsetY << "]}}";
            return j.str();
        }

        // Reset per-request accumulators
        docOriAngle_ = 0;
        unwarpApplied_ = false;
        textlineOriApplied_ = 0;

        try {
            // ── Step 1: Decode PNG → rgb[w × h × 3] ──
            int w = 0, h = 0, comp = 0;
            uint8_t* raw = stbi_load_from_memory(
                pngBytes.data(), (int)pngBytes.size(), &w, &h, &comp, 3);
            if (!raw) {
                std::ostringstream j;
                j << "{\"ok\":false,\"error\":\"png_decode\",\"stage\":\"decode\""
                  << ",\"reason\":\"stbi_load_from_memory failed\""
                  << ",\"input\":{\"offset\":[" << cropOffsetX << "," << cropOffsetY << "]}}";
                return j.str();
            }
            std::vector<uint8_t> rgb(raw, raw + (size_t)w * (size_t)h * 3);
            stbi_image_free(raw);

            if (w < 4 || h < 4) {
                std::ostringstream j;
                j << "{\"ok\":false,\"error\":\"image_too_small\",\"stage\":\"decode\""
                  << ",\"reason\":\"Image too small: " << w << "x" << h << "\""
                  << ",\"input\":{\"offset\":[" << cropOffsetX << "," << cropOffsetY << "]}}";
                return j.str();
            }

            const int origW = w, origH = h;

            // ── Step 2: Document orientation classification ──
            if (docOriAvailable_) {
                auto oriResult = DocOrientationClassify(rgb, w, h);
                docOriAngle_ = oriResult.angle;
                if (oriResult.angle == 180) {
                    RotateImage180(rgb, w, h);
                    DEBUG_PRINTF("[OCR pipe] Step2 doc_ori: angle=180 → rotated\n");
                } else if (oriResult.angle == 90) {
                    rgb = RotateImage90CW(rgb, w, h);
                    std::swap(w, h);
                    DEBUG_PRINTF("[OCR pipe] Step2 doc_ori: angle=90 → rotated CW (now %dx%d)\n", w, h);
                } else if (oriResult.angle == 270) {
                    rgb = RotateImage90CCW(rgb, w, h);
                    std::swap(w, h);
                    DEBUG_PRINTF("[OCR pipe] Step2 doc_ori: angle=270 → rotated CCW (now %dx%d)\n", w, h);
                } else {
                    DEBUG_PRINTF("[OCR pipe] Step2 doc_ori: angle=0 → no rotation\n");
                }
            } else {
                DEBUG_PRINTF("[OCR pipe] Step2 doc_ori: not loaded, skip\n");
            }

            // ── Step 3: Text image unwarping (UVDoc) ──
            if (enableUnwarp && unwarpAvailable_) {
                auto unwarpResult = TextUnwarping(rgb, w, h);
                if (unwarpResult.ok) {
                    rgb = unwarpResult.rgb;
                    if (unwarpResult.newW != w || unwarpResult.newH != h) {
                        w = unwarpResult.newW;
                        h = unwarpResult.newH;
                    }
                    unwarpApplied_ = true;
                    DEBUG_PRINTF("[OCR pipe] Step3 unwarp: applied (%dx%d)\n", w, h);
                } else {
                    DEBUG_PRINTF("[OCR pipe] Step3 unwarp: failed, using original\n");
                }
            } else {
                DEBUG_PRINTF("[OCR pipe] Step3 unwarp: %s\n",
                       enableUnwarp ? "not loaded, skip" : "disabled by user");
            }

            // ── Step 4: Text detection ──
            auto boxes = Detect(rgb, w, h);
            SortBoxes(boxes);
            DEBUG_PRINTF("[OCR pipe] Step4 det: %zu boxes (crop=%dx%d)\n", boxes.size(), w, h);

            // ── Step 5: Text line orientation classification (per box) ──
            if (textlineOriAvailable_ && !boxes.empty()) {
                DEBUG_PRINTF("[OCR pipe] Step5 textline_ori: classifying %zu boxes\n", boxes.size());
                for (size_t bi = 0; bi < boxes.size(); bi++) {
                    auto oriResult = TextlineOrientationClassify(rgb, w, h, boxes[bi]);
                    if (oriResult.is180) {
                        // Flip box corners: TL↔BR, TR↔BL
                        std::swap(boxes[bi].box[0], boxes[bi].box[2]);
                        std::swap(boxes[bi].box[1], boxes[bi].box[3]);
                        textlineOriApplied_++;
                        DEBUG_PRINTF("[OCR pipe]   box[%zu] flipped 180° (prob=%.4f)\n",
                               bi, oriResult.prob180);
                    }
                }
            } else {
                DEBUG_PRINTF("[OCR pipe] Step5 textline_ori: not loaded or no boxes, skip\n");
            }

            // ── Step 6: Recognition ──
            DEBUG_PRINTF("[OCR pipe] Step6 rec: %zu boxes\n", boxes.size());
            for (size_t bi = 0; bi < boxes.size(); bi++) {
                boxes[bi].text = RecognizeBox(rgb, w, h, boxes[bi]);
                boxes[bi].text = InsertSpaces(boxes[bi].text);
                if (bpeAvailable_) {
                    boxes[bi].text = ApplyBpeSegmentation(boxes[bi].text, *bpeTokenizer_);
                }
                DEBUG_PRINTF("[OCR text] box[%zu]=\"%s\" score=%.4f\n",
                       bi, boxes[bi].text.c_str(),
                       (double)boxes[bi].score);
            }

            // ── Step 7: Build JSON — per-box quads + offset translation ──
            std::ostringstream json;
            json << "{\"ok\":true"
                 << ",\"boxes\":[";
            for (size_t i = 0; i < boxes.size(); i++) {
                if (i > 0) json << ",";
                json << "{\"text\":\"" << esc(boxes[i].text) << "\""
                     << ",\"score\":" << boxes[i].score
                     << ",\"quad\":[";
                for (size_t p = 0; p < boxes[i].box.size(); p++) {
                    if (p > 0) json << ",";
                    json << "["
                         << (boxes[i].box[p].first  + (float)cropOffsetX)
                         << ","
                         << (boxes[i].box[p].second + (float)cropOffsetY)
                         << "]";
                }
                json << "]}";
            }
            json << "]";

            // Backward compat: legacy blocks[] array
            json << ",\"blocks\":[";
            for (size_t i = 0; i < boxes.size(); i++) {
                if (i > 0) json << ",";
                float bx1 = 1e9f, by1 = 1e9f, bx2 = -1e9f, by2 = -1e9f;
                for (const auto& pt : boxes[i].box) {
                    float px = pt.first  + (float)cropOffsetX;
                    float py = pt.second + (float)cropOffsetY;
                    if (px < bx1) bx1 = px; if (px > bx2) bx2 = px;
                    if (py < by1) by1 = py; if (py > by2) by2 = py;
                }
                json << "{\"text\":\"" << esc(boxes[i].text) << "\""
                     << ",\"x\":" << bx1 << ",\"y\":" << by1
                     << ",\"w\":" << (bx2 - bx1) << ",\"h\":" << (by2 - by1)
                     << "}";
            }
            json << "]";

            // Backward compat: fullText
            json << ",\"fullText\":\"";
            for (size_t i = 0; i < boxes.size(); i++) {
                if (i > 0) json << "\\n";
                json << esc(boxes[i].text);
            }
            json << "\""
                 << ",\"language\":\"ch\"";

            // Diag
            json << ",\"diag\":{"
                 << "\"stage\":\"success\""
                 << ",\"engine_src\":\"ppocrv6_onnx\""
                 << ",\"pipeline\":\"v3_doc_ori_unwarp_textline_ori_det_rec\""
                 << ",\"box_count\":" << boxes.size()
                 << ",\"crop_offset\":[" << cropOffsetX << "," << cropOffsetY << "]"
                 << ",\"img_size\":\"" << origW << "x" << origH << "\""
                 << ",\"img_after_preproc\":\"" << w << "x" << h << "\""
                 << ",\"doc_ori_enabled\":" << (docOriAvailable_ ? "true" : "false")
                 << ",\"doc_ori_angle\":" << docOriAngle_
                 << ",\"unwarp_enabled\":" << (unwarpAvailable_ ? "true" : "false")
                 << ",\"unwarp_applied\":" << (unwarpApplied_ ? "true" : "false")
                 << ",\"textline_ori_enabled\":" << (textlineOriAvailable_ ? "true" : "false")
                 << ",\"textline_ori_applied\":" << textlineOriApplied_
                 << ",\"det_model\":\"" << esc(detModelName_) << "\""
                 << ",\"rec_model\":\"" << esc(recModelName_) << "\""
                 << ",\"rec_T\":" << lastRecT_
                 << ",\"rec_C\":" << lastRecC_
                 << ",\"rec_best_text_len\":" << lastRecBestLen_
                 << ",\"rec_best_score\":" << lastRecBestScore_
                 << ",\"rec_input_w\":" << lastRecInputW_
                 << ",\"det_stride\":" << lastDetStride_
                 << ",\"det_in_hw\":\"" << lastDetInputH_ << "x" << lastDetInputW_ << "\""
                 << ",\"det_out_hw\":\"" << lastDetOutputH_ << "x" << lastDetOutputW_ << "\""
                 << "}}";
            return json.str();

        } catch (const Ort::Exception& e) {
            std::ostringstream j;
            j << "{\"ok\":false,\"error\":\"onnx\",\"stage\":\"inference\""
              << ",\"reason\":\"" << esc(e.what()) << "\"}";
            return j.str();
        } catch (const std::exception& e) {
            std::ostringstream j;
            j << "{\"ok\":false,\"error\":\"exception\",\"stage\":\"exception\""
              << ",\"reason\":\"" << esc(e.what()) << "\"}";
            return j.str();
        }
    }

private:
    // ────────────────────────────────────────────────────────────────────────
    // PP-OCRv6 Module 1: Document Orientation Classification
    //   Model: PP-LCNet_x1_0_doc_ori  (4-class: 0/90/180/270)
    //   Input: [1, 3, 224, 224]  float32 CHW, normalized
    // ────────────────────────────────────────────────────────────────────────
    struct DocOriResult { int angle = 0; };  // 0, 90, 180, or 270

    DocOriResult DocOrientationClassify(const std::vector<uint8_t>& rgb,
                                         int srcW, int srcH) {
        DocOriResult result;
        if (!docOriAvailable_) return result;

        try {
            // Query model input shape to determine target size
            auto inTypeInfo = docOriSession_->GetInputTypeInfo(0);
            auto inTensorInfo = inTypeInfo.GetTensorTypeAndShapeInfo();
            auto inShape = inTensorInfo.GetShape();

            int targetH = 224, targetW = 224;
            // If shape[2] and shape[3] are fixed, use them
            if (inShape.size() >= 4 && inShape[2] > 0 && inShape[3] > 0) {
                targetH = (int)inShape[2];
                targetW = (int)inShape[3];
            }

            DEBUG_PRINTF("[OCR doc_ori] input shape: [%lld,%lld,%lld,%lld] target=%dx%d\n",
                   (long long)(inShape.size()>0?inShape[0]:-1),
                   (long long)(inShape.size()>1?inShape[1]:-1),
                   (long long)(inShape.size()>2?inShape[2]:-1),
                   (long long)(inShape.size()>3?inShape[3]:-1),
                   targetW, targetH);

            // Resize to target size
            std::vector<uint8_t> resized(targetW * targetH * 3);
            bilinearResize(rgb.data(), srcW, srcH, 3, resized.data(), targetW, targetH);

            // Normalize: CHW, mean=0.5, std=0.5 → range [-1, 1]
            const float mean = 0.5f, stdv = 0.5f;
            std::vector<float> input(3 * targetH * targetW);
            for (int c = 0; c < 3; c++) {
                for (int y = 0; y < targetH; y++) {
                    for (int x = 0; x < targetW; x++) {
                        float v = (float)resized[(y * targetW + x) * 3 + c] / 255.0f;
                        v = (v - mean) / stdv;
                        input[c * targetH * targetW + y * targetW + x] = v;
                    }
                }
            }

            // Run inference
            auto memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
            std::array<int64_t, 4> shape{1, 3, (int64_t)targetH, (int64_t)targetW};
            auto tensor = Ort::Value::CreateTensor<float>(
                memoryInfo, input.data(), input.size(), shape.data(), shape.size());

            const char* inNames[] = {docOriInputName_.c_str()};
            const char* outNames[] = {docOriOutputName_.c_str()};
            auto outputs = docOriSession_->Run(Ort::RunOptions{nullptr},
                                               inNames, &tensor, 1, outNames, 1);

            float* logits = outputs[0].GetTensorMutableData<float>();
            auto outShape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();

            // Find argmax among 4 classes
            int nCls = 4;
            if (outShape.size() >= 2) nCls = (int)outShape[outShape.size() - 1];

            int bestClass = 0;
            float bestVal = logits[0];
            for (int i = 1; i < nCls; i++) {
                if (logits[i] > bestVal) { bestVal = logits[i]; bestClass = i; }
            }

            // Map class to angle: 0→0°, 1→90°, 2→180°, 3→270°
            static const int angleMap[] = {0, 90, 180, 270};
            result.angle = (bestClass < 4) ? angleMap[bestClass] : 0;

            DEBUG_PRINTF("[OCR doc_ori] class=%d angle=%d (logits: %.4f %.4f %.4f %.4f)\n",
                   bestClass, result.angle,
                   nCls > 0 ? logits[0] : 0.0f,
                   nCls > 1 ? logits[1] : 0.0f,
                   nCls > 2 ? logits[2] : 0.0f,
                   nCls > 3 ? logits[3] : 0.0f);

        } catch (const std::exception& e) {
            printf("[OCR doc_ori] inference failed: %s — returning angle=0\n", e.what());
            fflush(stdout);
            result.angle = 0;
        }

        return result;
    }

    // ────────────────────────────────────────────────────────────────────────
    // PP-OCRv6 Module 2: Text Image Unwarping (UVDoc)
    //   Model: UVDoc
    //   Input:  [1, 3, H, W]  float32 CHW, normalized
    //   Output: [1, 3, H, W]  float32 CHW, normalized (corrected image)
    // ────────────────────────────────────────────────────────────────────────
    struct UnwarpResult {
        bool ok = false;
        std::vector<uint8_t> rgb;
        int newW = 0, newH = 0;
    };

    UnwarpResult TextUnwarping(const std::vector<uint8_t>& rgb, int srcW, int srcH) {
        UnwarpResult result;
        if (!unwarpAvailable_) return result;

        try {
            // Query model input shape
            auto inTypeInfo = unwarpSession_->GetInputTypeInfo(0);
            auto inTensorInfo = inTypeInfo.GetTensorTypeAndShapeInfo();
            auto inShape = inTensorInfo.GetShape();

            int targetH = srcH, targetW = srcW;
            // If fixed dimensions, resize to match
            if (inShape.size() >= 4 && inShape[2] > 0 && inShape[3] > 0) {
                targetH = (int)inShape[2];
                targetW = (int)inShape[3];
            }

            // Resize to target size
            std::vector<uint8_t> resized(targetW * targetH * 3);
            bilinearResize(rgb.data(), srcW, srcH, 3, resized.data(), targetW, targetH);

            // Normalize: CHW, mean=0.5, std=0.5
            const float mean = 0.5f, stdv = 0.5f;
            std::vector<float> input(3 * targetH * targetW);
            for (int c = 0; c < 3; c++) {
                for (int y = 0; y < targetH; y++) {
                    for (int x = 0; x < targetW; x++) {
                        float v = (float)resized[(y * targetW + x) * 3 + c] / 255.0f;
                        v = (v - mean) / stdv;
                        input[c * targetH * targetW + y * targetW + x] = v;
                    }
                }
            }

            // Run inference
            auto memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
            std::array<int64_t, 4> shape{1, 3, (int64_t)targetH, (int64_t)targetW};
            auto tensor = Ort::Value::CreateTensor<float>(
                memoryInfo, input.data(), input.size(), shape.data(), shape.size());

            const char* inNames[] = {unwarpInputName_.c_str()};
            const char* outNames[] = {unwarpOutputName_.c_str()};
            auto outputs = unwarpSession_->Run(Ort::RunOptions{nullptr},
                                               inNames, &tensor, 1, outNames, 1);

            // Extract output image
            float* outData = outputs[0].GetTensorMutableData<float>();
            auto outShape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();

            int outH = targetH, outW = targetW;
            if (outShape.size() >= 4) {
                outH = (int)outShape[2];
                outW = (int)outShape[3];
            }

            // Denormalize: CHW → HWC uint8
            std::vector<uint8_t> outRgb(outW * outH * 3);
            for (int c = 0; c < 3; c++) {
                for (int y = 0; y < outH; y++) {
                    for (int x = 0; x < outW; x++) {
                        float v = outData[c * outH * outW + y * outW + x];
                        v = v * stdv + mean;  // denormalize
                        v = v * 255.0f;
                        v = std::max(0.0f, std::min(255.0f, v));
                        outRgb[(y * outW + x) * 3 + c] = (uint8_t)(v + 0.5f);
                    }
                }
            }

            result.ok = true;
            result.rgb = outRgb;
            result.newW = outW;
            result.newH = outH;

            DEBUG_PRINTF("[OCR unwarp] %dx%d → %dx%d ok\n", srcW, srcH, outW, outH);

        } catch (const std::exception& e) {
            printf("[OCR unwarp] inference failed: %s\n", e.what());
            fflush(stdout);
            result.ok = false;
        }

        return result;
    }

    // ────────────────────────────────────────────────────────────────────────
    // PP-OCRv6 Module 3: Text Line Orientation Classification
    //   Model: PP-LCNet_x1_0_textline_ori  (2-class: 0°/180°)
    //   Input:  [1, 3, 48, 192]  float32 CHW, normalized
    //   Output: [1, 2] softmax
    // ────────────────────────────────────────────────────────────────────────
    struct TextlineOriResult {
        bool is180 = false;
        float prob180 = 0.0f;
    };

    TextlineOriResult TextlineOrientationClassify(
        const std::vector<uint8_t>& rgb, int srcW, int srcH,
        const TextBox& box)
    {
        TextlineOriResult result;
        if (!textlineOriAvailable_) return result;

        try {
            // Crop the box region
            float minX = box.box[0].first, maxX = minX;
            float minY = box.box[0].second, maxY = minY;
            for (const auto& pt : box.box) {
                minX = (std::min)(minX, pt.first);
                maxX = (std::max)(maxX, pt.first);
                minY = (std::min)(minY, pt.second);
                maxY = (std::max)(maxY, pt.second);
            }

            int cx = (int)(std::max)(0.0f, minX);
            int cy = (int)(std::max)(0.0f, minY);
            int cw = (int)(std::min)((float)srcW, maxX) - cx;
            int ch = (int)(std::min)((float)srcH, maxY) - cy;
            if (cw < 8 || ch < 8) return result;
            if (cw > srcW || ch > srcH) return result;

            // Query model input shape
            auto inTypeInfo = textlineOriSession_->GetInputTypeInfo(0);
            auto inTensorInfo = inTypeInfo.GetTensorTypeAndShapeInfo();
            auto inShape = inTensorInfo.GetShape();

            int targetH = 48, targetW = 192;
            if (inShape.size() >= 4 && inShape[2] > 0) targetH = (int)inShape[2];
            if (inShape.size() >= 4 && inShape[3] > 0) targetW = (int)inShape[3];

            // Crop + resize
            std::vector<uint8_t> crop(cw * ch * 3);
            for (int y = 0; y < ch; y++)
                memcpy(crop.data() + y * cw * 3,
                       rgb.data() + ((cy + y) * srcW + cx) * 3, cw * 3);

            std::vector<uint8_t> resized(targetW * targetH * 3);
            bilinearResize(crop.data(), cw, ch, 3, resized.data(), targetW, targetH);

            // Normalize: CHW, mean=0.5, std=0.5
            const float mean = 0.5f, stdv = 0.5f;
            std::vector<float> input(3 * targetH * targetW);
            for (int c = 0; c < 3; c++) {
                for (int y = 0; y < targetH; y++) {
                    for (int x = 0; x < targetW; x++) {
                        float v = (float)resized[(y * targetW + x) * 3 + c] / 255.0f;
                        v = (v - mean) / stdv;
                        input[c * targetH * targetW + y * targetW + x] = v;
                    }
                }
            }

            // Run inference
            auto memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
            std::array<int64_t, 4> shape{1, 3, (int64_t)targetH, (int64_t)targetW};
            auto tensor = Ort::Value::CreateTensor<float>(
                memoryInfo, input.data(), input.size(), shape.data(), shape.size());

            const char* inNames[] = {textlineOriInputName_.c_str()};
            const char* outNames[] = {textlineOriOutputName_.c_str()};
            auto outputs = textlineOriSession_->Run(Ort::RunOptions{nullptr},
                                                    inNames, &tensor, 1, outNames, 1);

            float* logits = outputs[0].GetTensorMutableData<float>();
            auto outShape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();
            int nCls = (int)(outShape.size() >= 2 ? outShape[outShape.size() - 1] : 2);
            if (nCls < 2) return result;

            // Softmax for class 1 (180°)
            float s0 = logits[0], s1 = logits[1];
            float maxVal = (std::max)(s0, s1);
            float exp0 = std::exp(s0 - maxVal);
            float exp1 = std::exp(s1 - maxVal);
            result.prob180 = exp1 / (exp0 + exp1);
            result.is180 = (result.prob180 > 0.9f);

        } catch (const std::exception& e) {
            printf("[OCR textline_ori] inference failed: %s\n", e.what());
            fflush(stdout);
        }

        return result;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Detection preprocessing  (unchanged from PP-OCRv5, compatible with v6)
    // ────────────────────────────────────────────────────────────────────────
    std::vector<float> PreprocessDet(const std::vector<uint8_t>& rgb,
                                      int srcW, int srcH,
                                      int& outW, int& outH, float& outScale) {
        int maxDim = (std::max)(srcW, srcH);
        float scale = 1.0f;
        if (maxDim > 960) {
            scale = 960.0f / (float)maxDim;
        }
        int newW = (int)((float)srcW * scale);
        int newH = (int)((float)srcH * scale);
        if (newW < 1) newW = 1;
        if (newH < 1) newH = 1;

        std::vector<uint8_t> resized(newW * newH * 3);
        bilinearResize(rgb.data(), srcW, srcH, 3, resized.data(), newW, newH);

        int padW = (32 - newW % 32) % 32;
        int padH = (32 - newH % 32) % 32;
        int paddedW = newW + padW;
        int paddedH = newH + padH;

        std::vector<float> chw(3 * paddedW * paddedH, 0.0f);

        auto* padImg = (uint8_t*)malloc(paddedW * paddedH * 3);
        for (int i = 0; i < paddedW * paddedH * 3; i++) padImg[i] = 114;
        for (int y = 0; y < newH; y++) {
            memcpy(padImg + y * paddedW * 3, resized.data() + y * newW * 3, newW * 3);
        }

        const float mean[3] = {0.485f, 0.456f, 0.406f};
        const float stdv[3] = {0.229f, 0.224f, 0.225f};

        for (int c = 0; c < 3; c++) {
            for (int y = 0; y < paddedH; y++) {
                for (int x = 0; x < paddedW; x++) {
                    float v = (float)padImg[(y * paddedW + x) * 3 + c] / 255.0f;
                    v = (v - mean[c]) / stdv[c];
                    chw[c * paddedH * paddedW + y * paddedW + x] = v;
                }
            }
        }
        free(padImg);

        outW = paddedW;
        outH = paddedH;
        outScale = scale;
        return chw;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Recognition preprocessing (perspective rectification + resize)
    // ────────────────────────────────────────────────────────────────────────
    std::vector<float> PreprocessRec(const std::vector<uint8_t>& rgb,
                                      int srcW, int srcH,
                                      const TextBox& box,
                                      int& outW) {
        DEBUG_PRINTF("[OCR warp] rawCorners=(%.1f,%.1f) (%.1f,%.1f) (%.1f,%.1f) (%.1f,%.1f)\n",
               box.box[0].first, box.box[0].second,
               box.box[1].first, box.box[1].second,
               box.box[2].first, box.box[2].second,
               box.box[3].first, box.box[3].second);

        float x0, y0, x1, y1, x2, y2, x3, y3;
        orderBoxCorners(box.box, x0, y0, x1, y1, x2, y2, x3, y3);

        float topLen    = ptDist(x0, y0, x1, y1);
        float bottomLen = ptDist(x3, y3, x2, y2);
        float leftLen   = ptDist(x0, y0, x3, y3);
        float rightLen  = ptDist(x1, y1, x2, y2);
        float rawW = (topLen + bottomLen) * 0.5f;
        float rawH = (leftLen + rightLen) * 0.5f;
        if (rawW < 2.0f) rawW = 2.0f;
        if (rawH < 2.0f) rawH = 2.0f;

        float padX = (std::max)(1.0f, rawW * 0.05f);
        float padY = (std::max)(2.0f, rawH * 0.25f);

        // ── Expand source corners vertically to capture ascenders/descenders ──
        // PP-OCRv6 detection boxes are tight around x-height (baseline→cap-height).
        // English letters with ascenders (l,t,h,k,d,b) and descenders (y,g,p,q,j)
        // extend beyond the detection box. Push top corners up and bottom corners
        // down so the warp captures the full glyph extent.
        {
            float expandY = rawH * 0.60f;
            y0 -= expandY;  // TL up
            y1 -= expandY;  // TR up
            y2 += expandY;  // BR down
            y3 += expandY;  // BL down
            // Clamp to image bounds
            if (y0 < 0) y0 = 0;  if (y1 < 0) y1 = 0;
            if (y2 >= srcH) y2 = (float)(srcH - 1);
            if (y3 >= srcH) y3 = (float)(srcH - 1);
            // Recompute rawH after expansion
            leftLen  = ptDist(x0, y0, x3, y3);
            rightLen = ptDist(x1, y1, x2, y2);
            rawH = (leftLen + rightLen) * 0.5f;
            if (rawH < 2.0f) rawH = 2.0f;
        }

        int padL = (int)std::ceil(padX);
        int padR = (int)std::ceil(padX);
        int padT = (int)std::ceil(padY);
        int padB = (int)std::ceil(padY);
        int baseW = (int)std::ceil(rawW);
        int baseH = (int)std::ceil(rawH);
        int paddedW = baseW + padL + padR;
        int paddedH = baseH + padT + padB;

        float dTLx = (float)padL,         dTLy = (float)padT;
        float dTRx = (float)(padL + baseW), dTRy = (float)padT;
        float dBRx = (float)(padL + baseW), dBRy = (float)(padT + baseH);
        float dBLx = (float)padL,         dBLy = (float)(padT + baseH);

        double H[9];
        bool warpOk = computePerspective(
            dTLx,dTLy, x0,y0,  dTRx,dTRy, x1,y1,
            dBRx,dBRy, x2,y2,  dBLx,dBLy, x3,y3, H);

        double repMax = 0.0, repSum = 0.0;
        if (warpOk) {
            struct { float sx, sy, dx, dy; } check[4] = {
                {x0,y0, dTLx,dTLy}, {x1,y1, dTRx,dTRy},
                {x2,y2, dBRx,dBRy}, {x3,y3, dBLx,dBLy}
            };
            for (int i = 0; i < 4; i++) {
                double denom = H[6]*(double)check[i].dx + H[7]*(double)check[i].dy + H[8];
                if (std::abs(denom) < 1e-9) { repMax = 1e9f; break; }
                double rx = (H[0]*(double)check[i].dx + H[1]*(double)check[i].dy + H[2]) / denom;
                double ry = (H[3]*(double)check[i].dx + H[4]*(double)check[i].dy + H[5]) / denom;
                double err = std::sqrt((rx-check[i].sx)*(rx-check[i].sx) +
                                       (ry-check[i].sy)*(ry-check[i].sy));
                repSum += err;
                if (err > repMax) repMax = err;
            }
            if (repMax > 10.0) warpOk = false;
        }

        std::vector<uint8_t> crop;
        int cw = 0, ch = 0;
        if (warpOk) {
            lastRecWarped_ = true;
            crop = warpPerspective(rgb.data(), srcW, srcH, paddedW, paddedH, H);
            cw = paddedW;
            ch = paddedH;
        } else {
            lastRecWarped_ = false;
            // Use expanded corners (x0..y3) for AABB, not raw box.box
            float minX = x0, maxX = x0, minY = y0, maxY = y0;
            minX = (std::min)(minX, x1); maxX = (std::max)(maxX, x1);
            minX = (std::min)(minX, x2); maxX = (std::max)(maxX, x2);
            minX = (std::min)(minX, x3); maxX = (std::max)(maxX, x3);
            minY = (std::min)(minY, y1); maxY = (std::max)(maxY, y1);
            minY = (std::min)(minY, y2); maxY = (std::max)(maxY, y2);
            minY = (std::min)(minY, y3); maxY = (std::max)(maxY, y3);
            float fPadX = (std::max)(1.0f, (maxX-minX) * 0.05f);
            float fPadY = (std::max)(2.0f, (maxY-minY) * 0.50f);
            int fcx = (int)std::floor((std::max)(0.0f, minX - fPadX));
            int fcy = (int)std::floor((std::max)(0.0f, minY - fPadY));
            cw = (int)std::ceil((std::min)((float)srcW, maxX + fPadX)) - fcx;
            ch = (int)std::ceil((std::min)((float)srcH, maxY + fPadY)) - fcy;
            if (fcx < 0) { cw += fcx; fcx = 0; }
            if (fcy < 0) { ch += fcy; fcy = 0; }
            if (fcx + cw > srcW) cw = srcW - fcx;
            if (fcy + ch > srcH) ch = srcH - fcy;
            if (cw < 2) cw = 2;
            if (ch < 2) ch = 2;
            crop.resize(cw * ch * 3);
            for (int y = 0; y < ch; y++) {
                memcpy(crop.data() + y*cw*3,
                       rgb.data() + ((fcy+y)*srcW + fcx)*3, cw*3);
            }
            paddedW = cw; paddedH = ch;
        }

        lastRecRawW_ = rawW;  lastRecRawH_ = rawH;
        lastRecPadX_ = padX;  lastRecPadY_ = padY;

        DEBUG_PRINTF("[OCR crop] raw=(%.0f,%.0f,%.0f,%.0f) padded=(%d,%d,%d,%d) padXY=(%.1f,%.1f) warp=%d\n",
               x0, y0, rawW, rawH, 0, 0, cw, ch, padX, padY, (int)warpOk);

        const int targetH = 48;
        const int maxW    = 480;
        float ratio = (float)cw / (float)ch;
        int targetW = (int)((float)targetH * ratio);
        if (targetW < 8)  targetW = 8;
        if (targetW > maxW) targetW = maxW;

        std::vector<uint8_t> resized(targetW * targetH * 3);
        bilinearResize(crop.data(), cw, ch, 3, resized.data(), targetW, targetH);

        int finalW = ((targetW + 7) / 8) * 8;

        const float recMean[3] = {0.5f, 0.5f, 0.5f};
        const float recStdv[3] = {0.5f, 0.5f, 0.5f};

        const float padPixel = 0.0f / 255.0f;
        std::vector<float> chwData(3 * targetH * finalW);
        for (int c = 0; c < 3; c++) {
            float fillVal = (padPixel - recMean[c]) / recStdv[c];
            for (int y = 0; y < targetH; y++) {
                for (int x = 0; x < finalW; x++) {
                    float v;
                    if (x < targetW) {
                        v = (float)resized[(y * targetW + x) * 3 + c] / 255.0f;
                        v = (v - recMean[c]) / recStdv[c];
                    } else {
                        v = fillVal;
                    }
                    chwData[c * targetH * finalW + y * finalW + x] = v;
                }
            }
        }

        outW = finalW;
        return chwData;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Detection inference + postprocessing
    // ────────────────────────────────────────────────────────────────────────
    std::vector<TextBox> Detect(const std::vector<uint8_t>& rgb, int srcW, int srcH) {
        int paddedW, paddedH;
        float scale;
        auto input = PreprocessDet(rgb, srcW, srcH, paddedW, paddedH, scale);

        auto memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::array<int64_t, 4> shape{1, 3, (int64_t)paddedH, (int64_t)paddedW};

        auto tensor = Ort::Value::CreateTensor<float>(
            memoryInfo, input.data(), input.size(), shape.data(), shape.size());

        const char* inNames[] = {detInputName_.c_str()};
        const char* outNames[] = {detOutputName_.c_str()};
        auto outputs = detSession_->Run(Ort::RunOptions{nullptr},
                                        inNames, &tensor, 1,
                                        outNames, 1);

        float* probMap = outputs[0].GetTensorMutableData<float>();
        auto outShape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();
        int outH, outW;
        if (outShape.size() == 4) {
            outH = (int)outShape[2];
            outW = (int)outShape[3];
        } else if (outShape.size() == 3) {
            outH = (int)outShape[1];
            outW = (int)outShape[2];
        } else {
            outH = paddedH;
            outW = paddedW;
        }

        return PostprocessDet(probMap, outW, outH, scale, srcW, srcH,
                              paddedH, paddedW);
    }

    // ────────────────────────────────────────────────────────────────────────
    // DB postprocessing
    // ────────────────────────────────────────────────────────────────────────
    std::vector<TextBox> PostprocessDet(const float* probMap,
                                         int ow, int oh,
                                         float scale, int srcW, int srcH,
                                         int paddedH, int paddedW) {
        float detStride = (float)paddedW / (float)ow;
        lastDetStride_  = (int)(detStride + 0.5f);
        lastDetInputH_  = paddedH;
        lastDetInputW_  = paddedW;
        lastDetOutputH_ = oh;
        lastDetOutputW_ = ow;

        std::vector<uint8_t> mask(ow * oh, 0);
        for (int y = 0; y < oh; y++) {
            for (int x = 0; x < ow; x++) {
                mask[y * ow + x] = (probMap[y * ow + x] > 0.3f) ? 1 : 0;
            }
        }

        auto components = connectedComponents(mask.data(), ow, oh, 15);

        std::vector<TextBox> boxes;
        for (const auto& comp : components) {
            int minX = ow, minY = oh, maxX = 0, maxY = 0;
            for (const auto& pt : comp) {
                minX = (std::min)(minX, pt.first);
                maxX = (std::max)(maxX, pt.first);
                minY = (std::min)(minY, pt.second);
                maxY = (std::max)(maxY, pt.second);
            }

            int boxW = maxX - minX + 1;
            int boxH = maxY - minY + 1;
            float expandRatio = 0.05f;
            int expandX = (int)(boxW * expandRatio);
            int expandY = (int)(boxH * expandRatio);
            minX = (std::max)(0, minX - expandX);
            minY = (std::max)(0, minY - expandY);
            maxX = (std::min)(ow - 1, maxX + expandX);
            maxY = (std::min)(oh - 1, maxY + expandY);

            float invScale = detStride / scale;
            TextBox tb;
            float ox1 = (float)minX * invScale;
            float oy1 = (float)minY * invScale;
            float ox2 = (float)(maxX + 1) * invScale;
            float oy2 = (float)(maxY + 1) * invScale;
            ox1 = (std::max)(0.0f, (std::min)(ox1, (float)srcW));
            oy1 = (std::max)(0.0f, (std::min)(oy1, (float)srcH));
            ox2 = (std::max)(0.0f, (std::min)(ox2, (float)srcW));
            oy2 = (std::max)(0.0f, (std::min)(oy2, (float)srcH));

            tb.box = {{ox1, oy1}, {ox2, oy1}, {ox2, oy2}, {ox1, oy2}};
            tb.score = 1.0f;
            boxes.push_back(tb);
        }

        return boxes;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Recognition for a single box
    // ────────────────────────────────────────────────────────────────────────
    std::string RecognizeBox(const std::vector<uint8_t>& rgb,
                              int srcW, int srcH,
                              const TextBox& box) {
        int recW;
        auto input = PreprocessRec(rgb, srcW, srcH, box, recW);
        lastRecInputW_ = recW;
        int recH = 48;

        auto memoryInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        std::array<int64_t, 4> shape{1, 3, (int64_t)recH, (int64_t)recW};

        auto tensor = Ort::Value::CreateTensor<float>(
            memoryInfo, input.data(), input.size(), shape.data(), shape.size());

        const char* inNames[] = {recInputName_.c_str()};
        const char* outNames[] = {recOutputName_.c_str()};
        auto outputs = recSession_->Run(Ort::RunOptions{nullptr},
                                        inNames, &tensor, 1,
                                        outNames, 1);

        float* logits = outputs[0].GetTensorMutableData<float>();
        auto outShape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();

        lastRecOutShape_ = "[";
        for (size_t i = 0; i < outShape.size(); i++) {
            if (i > 0) lastRecOutShape_ += ",";
            lastRecOutShape_ += std::to_string(outShape[i]);
        }
        lastRecOutShape_ += "]";

        int dim1 = (int)(outShape.size() > 1 ? outShape[1] : 1);
        int dim2 = (int)(outShape.size() > 2 ? outShape[2] : 1);
        int detectedDim = 0;
        int dictSize = (int)keys_.size();

        // Auto-detect time-major layout by finding which dimension
        // is closest to the dictionary size.  PP-OCRv6_small_rec output
        // is e.g. [1, T, 18710] vs dict=18708; PP-OCRv5 is [1, T, 18384]
        // vs dict=18383.  Tolerate ±dictSize/20 for cross-version compat.
        int tolerance = (std::max)(3, dictSize / 20);
        bool timeMajor = true;
        int modelC = 0;
        if (std::abs(dim1 - dictSize) <= tolerance) {
            timeMajor  = false;        // dim1 is classes, dim0 is time
            modelC     = dim1;
            detectedDim = 1;
        } else if (std::abs(dim2 - dictSize) <= tolerance) {
            timeMajor  = true;         // dim2 is classes, dim1 is time
            modelC     = dim2;
            detectedDim = 2;
        } else {
            // Fallback: pick the larger dim as the class axis
            modelC = (dim1 > dim2) ? dim1 : dim2;
            timeMajor = (dim2 == modelC);
            detectedDim = timeMajor ? 2 : 1;
        }

        auto r = CtcDecodeGeneric(logits, dim1, dim2,
                                   0 /*blankIdx*/, 1 /*keyStartIdx*/, timeMajor);

        if (r.text.empty()) {
            auto r2 = CtcDecodeGeneric(logits, dim1, dim2,
                                        modelC - 1 /*blankIdx*/, 0 /*keyStartIdx*/,
                                        timeMajor);
            if (!r2.text.empty()) r = r2;
        }

        if (r.text.empty()) {
            auto r3 = CtcDecodeGeneric(logits, dim1, dim2,
                                        0 /*blankIdx*/, 1 /*keyStartIdx*/,
                                        !timeMajor);
            if (!r3.text.empty()) r = r3;
        }

        std::ostringstream modeStr;
        modeStr << "shape=" << lastRecOutShape_
                << "_modelC=" << modelC << "_dictSize=" << dictSize
                << "_detectedCdim=" << detectedDim
                << "_chosen_blank=" << r.blankIdx
                << "_keyStart=" << r.keyStartIdx
                << "_tMaj=" << (r.timeMajor ? "1" : "0");
        lastRecDecodeMode_   = modeStr.str();
        lastRecT_            = r.T;
        lastRecC_            = r.C;
        lastRecBestLen_      = (int)r.text.size();
        lastRecBestScore_    = r.score;

        return r.text;
    }

    // ────────────────────────────────────────────────────────────────────────
    // Generic CTC greedy decode
    // ────────────────────────────────────────────────────────────────────────
    struct CtcResult {
        std::string text;
        double    score = -1e30;
        int blankIdx = 0;
        int keyStartIdx = 1;
        bool timeMajor = true;
        int T = 0;
        int C = 0;
    };

    CtcResult CtcDecodeGeneric(const float* logits, int dim0, int dim1,
                                int blankIdx, int keyStartIdx, bool timeMajor) {
        int T = timeMajor ? dim0 : dim1;
        int C = timeMajor ? dim1 : dim0;

        std::vector<int> indices(T);
        std::vector<float> maxLogits(T);

        for (int t = 0; t < T; t++) {
            float maxVal = -1e30f;
            int maxIdx = 0;
            for (int c = 0; c < C; c++) {
                float v = timeMajor ? logits[t * C + c] : logits[c * T + t];
                if (v > maxVal) { maxVal = v; maxIdx = c; }
            }
            indices[t] = maxIdx;
            maxLogits[t] = maxVal;
        }

        std::string result;
        double scoreSum = 0.0;
        int keepCount = 0;
        int prev = -1;
        for (int t = 0; t < T; t++) {
            int idx = indices[t];
            if (idx == blankIdx) { prev = -1; continue; }
            if (idx == prev) continue;
            prev = idx;
            int keyIdx = idx - keyStartIdx;
            if (keyIdx >= 0 && keyIdx < (int)keys_.size()) {
                result += keys_[keyIdx];
                scoreSum += (double)maxLogits[t];
                keepCount++;
            }
        }

        double score = (keepCount > 0) ? (scoreSum / (double)keepCount) : -1e30;
        return {result, score, blankIdx, keyStartIdx, timeMajor, T, C};
    }

    // ────────────────────────────────────────────────────────────────────────
    // Box sorting (top-to-bottom, left-to-right)
    // ────────────────────────────────────────────────────────────────────────
    void SortBoxes(std::vector<TextBox>& boxes) {
        if (boxes.size() <= 1) return;

        std::sort(boxes.begin(), boxes.end(), [](const TextBox& a, const TextBox& b) {
            float ay = 0.0f, ax = 0.0f, by = 0.0f, bx = 0.0f;
            for (const auto& pt : a.box) { ay += pt.second; ax += pt.first; }
            for (const auto& pt : b.box) { by += pt.second; bx += pt.first; }
            ay /= a.box.size(); ax /= a.box.size();
            by /= b.box.size(); bx /= b.box.size();
            float avgH = 0.0f;
            for (const auto& t : {a, b}) {
                float minY = t.box[0].second, maxY = minY;
                for (const auto& p : t.box) {
                    minY = (std::min)(minY, p.second); maxY = (std::max)(maxY, p.second);
                }
                avgH += (maxY - minY) / 2.0f;
            }
            if (std::abs(ay - by) < avgH * 0.5f) {
                return ax < bx;
            }
            return ay < by;
        });
    }

    // ────────────────────────────────────────────────────────────────────────
    // Members
    // ────────────────────────────────────────────────────────────────────────
    std::unique_ptr<Ort::Env> env_;
    Ort::AllocatorWithDefaultOptions allocator_;
    std::unique_ptr<Ort::Session> detSession_;
    std::unique_ptr<Ort::Session> recSession_;

    // PP-OCRv6 preprocessing modules (all optional)
    std::unique_ptr<Ort::Session> docOriSession_;
    std::unique_ptr<Ort::Session> unwarpSession_;
    std::unique_ptr<Ort::Session> textlineOriSession_;

    std::string detInputName_;
    std::string detOutputName_;
    std::string recInputName_;
    std::string recOutputName_;
    std::string docOriInputName_;
    std::string docOriOutputName_;
    std::string unwarpInputName_;
    std::string unwarpOutputName_;
    std::string textlineOriInputName_;
    std::string textlineOriOutputName_;

    std::vector<std::string> keys_;
    std::string modelDir_;

    bool initialized_ = false;
    std::string lastError_;

    // Model names loaded (for diag)
    std::string detModelName_ = "unknown";
    std::string recModelName_ = "unknown";
    std::string dictName_ = "unknown";

    // PP-OCRv6 preprocessing module availability
    bool docOriAvailable_ = false;
    bool unwarpAvailable_ = false;
    bool textlineOriAvailable_ = false;

    // GPT-2 BPE tokenizer (optional, for English word boundary recovery)
    std::unique_ptr<Gpt2BpeTokenizer> bpeTokenizer_;
    bool bpeAvailable_ = false;

    // Per-request accumulators
    int docOriAngle_ = 0;
    bool unwarpApplied_ = false;
    int textlineOriApplied_ = 0;

    // Diag tracking (per last RecognizeBox call)
    std::string lastRecOutShape_ = "[]";
    std::string lastRecDecodeMode_ = "none";
    int lastRecT_ = 0;
    int lastRecC_ = 0;
    int lastRecBestLen_ = 0;
    double lastRecBestScore_ = -1e30;
    int lastRecInputW_ = 0;
    int lastDetStride_ = 0;
    int lastDetInputH_ = 0;
    int lastDetInputW_ = 0;
    int lastDetOutputH_ = 0;
    int lastDetOutputW_ = 0;
    bool  lastRecWarped_ = false;
    float lastRecRawW_ = 0;
    float lastRecRawH_ = 0;
    float lastRecPadX_ = 0;
    float lastRecPadY_ = 0;
};

// ============================================================================
// Singleton engine — lazy init on first call
// ============================================================================

static std::unique_ptr<OnnxOcrEngine> g_engine;
static std::once_flag g_initFlag;
static std::mutex g_mutex;

static std::string GetModelDir() {
    wchar_t exePath[MAX_PATH];
    DWORD len = GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    if (len > 0) {
        std::filesystem::path exeDir = std::filesystem::path(exePath).parent_path();
        auto modelsDir = exeDir / "models";
        if (std::filesystem::exists(modelsDir)) {
            std::string result = modelsDir.string();
            std::replace(result.begin(), result.end(), '\\', '/');
            return result;
        }
    }
    return "e:/AI/XMate/windows/runner/native/models";
}

static OnnxOcrEngine& GetEngine() {
    std::call_once(g_initFlag, []() {
        g_engine = std::make_unique<OnnxOcrEngine>();
        std::string modelDir = GetModelDir();
        if (!g_engine->Initialize(modelDir)) {
            // Engine will return error JSON on Recognize() calls
        }
    });
    return *g_engine;
}

// ============================================================================
// Public API
// ============================================================================

std::string OcrFromPNG(const std::vector<uint8_t>& pngBytes) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return GetEngine().Recognize(pngBytes, 0, 0, false);
}

std::string OcrFromPNGWithOffset(const std::vector<uint8_t>& pngBytes,
                                 int cropX, int cropY, bool enableUnwarp) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return GetEngine().Recognize(pngBytes, cropX, cropY, enableUnwarp);
}
