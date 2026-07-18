// XMate - Offline EN->ZH translation engine (UTF-8 BOM)
//
// Uses ONNX Runtime for encoder-decoder transformer inference.
// Tokenizer: shared-vocab SpTokenizer (sp_tokenizer.cpp).
//
// Model files (in models_translate/, excluded from installer — downloaded on demand):
//   translate_encoder.onnx   - MarianMT encoder (FP32)
//   translate_decoder.onnx   - MarianMT decoder (FP32)
//   vocab.json               - 65,001 shared vocabulary (piece -> shared_id)
//   source.spm / target.spm  - original SP models (backup, not used at runtime)
//

#include "translate_engine.h"
#include "sp_tokenizer.h"

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <windows.h>

#pragma comment(lib, "onnxruntime.lib")

// ============================================================================
// Minimal JSON helpers
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

static std::vector<std::string> parseJsonStringArray(const std::string& json) {
    std::vector<std::string> out;
    bool inString = false;
    std::string cur;
    for (size_t i = 0; i < json.size(); i++) {
        char c = json[i];
        if (c == '"' && (i == 0 || json[i-1] != '\\')) {
            if (inString) { out.push_back(cur); cur.clear(); }
            inString = !inString;
        } else if (inString) {
            if (c == '\\' && i + 1 < json.size()) {
                i++;
                switch (json[i]) {
                    case 'n': cur += '\n'; break;
                    case 't': cur += '\t'; break;
                    case '\\': cur += '\\'; break;
                    case '"': cur += '"'; break;
                    default: cur += json[i]; break;
                }
            } else { cur += c; }
        }
    }
    return out;
}

// ============================================================================
// ONNX Translation Engine
// ============================================================================

class TranslateEngine {
public:
    ~TranslateEngine() = default;

    bool Initialize(const std::string& modelDir) {
        try {
            std::cerr << "[Translate] Initialize model dir: " << modelDir << std::endl;

            // Stage 0: Check all files exist
            {
                auto logFile = [&](const char* name) {
                    auto p = modelDir + "/" + name;
                    bool ok = std::filesystem::exists(p);
                    std::cerr << "[Translate]   file: " << name << " -> "
                              << (ok ? "found " : "MISSING ");
                    if (ok) {
                        auto sz = std::filesystem::file_size(p);
                        std::cerr << "(" << (sz / 1024 / 1024) << " MB)";
                    }
                    std::cerr << std::endl;
                    return ok;
                };
                logFile("translate_encoder.onnx");
                logFile("translate_decoder.onnx");
                logFile("vocab.json");
            }

            // Stage 1: Load shared vocab tokenizer
            std::cerr << "[Translate] Stage 1/2: Loading shared vocab..." << std::endl;
            if (!tokenizer_.Load(modelDir)) {
                lastError_ = tokenizer_.GetLastError();
                std::cerr << "[Translate]   FAILED: " << lastError_ << std::endl;
                return false;
            }
            std::cerr << "[Translate]   Shared vocab OK, entries="
                      << idToPieceSize_() << std::endl;

            // Stage 2: ONNX sessions
            std::cerr << "[Translate] Stage 2/2: Loading ONNX sessions..." << std::endl;
            env_ = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "XMateTrans");

            Ort::SessionOptions opts;
            opts.SetIntraOpNumThreads(2);
            opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_EXTENDED);

            // Encoder
            {
                std::string path = modelDir + "/translate_encoder.onnx";
                if (!std::filesystem::exists(path)) {
                    lastError_ = "translate_encoder.onnx not found";
                    std::cerr << "[Translate]   " << lastError_ << std::endl;
                    return false;
                }
                std::wstring wp(path.begin(), path.end());
                encSession_ = std::make_unique<Ort::Session>(*env_, wp.c_str(), opts);
                for (size_t i = 0; i < encSession_->GetInputCount(); i++) {
                    auto n = encSession_->GetInputNameAllocated(i, alloc_);
                    encInNames_.push_back(std::string(n.get()));
                }
                for (size_t i = 0; i < encSession_->GetOutputCount(); i++) {
                    auto n = encSession_->GetOutputNameAllocated(i, alloc_);
                    encOutNames_.push_back(std::string(n.get()));
                }
                std::cerr << "[Translate]   Encoder OK, inputs=" << encInNames_.size()
                          << " outputs=" << encOutNames_.size() << std::endl;
            }

            // Decoder
            {
                std::string path = modelDir + "/translate_decoder.onnx";
                if (!std::filesystem::exists(path)) {
                    lastError_ = "translate_decoder.onnx not found";
                    std::cerr << "[Translate]   " << lastError_ << std::endl;
                    return false;
                }
                std::wstring wp(path.begin(), path.end());
                decSession_ = std::make_unique<Ort::Session>(*env_, wp.c_str(), opts);
                for (size_t i = 0; i < decSession_->GetInputCount(); i++) {
                    auto n = decSession_->GetInputNameAllocated(i, alloc_);
                    decInNames_.push_back(std::string(n.get()));
                }
                for (size_t i = 0; i < decSession_->GetOutputCount(); i++) {
                    auto n = decSession_->GetOutputNameAllocated(i, alloc_);
                    decOutNames_.push_back(std::string(n.get()));
                }
                std::cerr << "[Translate]   Decoder OK, inputs=" << decInNames_.size()
                          << " outputs=" << decOutNames_.size() << std::endl;
            }

            modelDir_ = modelDir;
            initialized_ = true;
            std::cerr << "[Translate] Initialize SUCCESS." << std::endl;
            return true;

        } catch (const Ort::Exception& e) {
            lastError_ = std::string("ONNX init error: ") + e.what();
            std::cerr << "[Translate] Initialize CATCH(Ort): " << lastError_ << std::endl;
            return false;
        } catch (const std::exception& e) {
            lastError_ = std::string("Init error: ") + e.what();
            std::cerr << "[Translate] Initialize CATCH(std): " << lastError_ << std::endl;
            return false;
        } catch (...) {
            lastError_ = "Init error: unknown exception";
            std::cerr << "[Translate] Initialize CATCH(...): unknown exception" << std::endl;
            return false;
        }
    }

    bool IsInitialized() const { return initialized_; }
    std::string GetLastError() const { return lastError_; }

    std::string Translate(const std::string& text) {
        if (!initialized_) return "[model not loaded]";

        try {
            // Shared vocab special IDs
            const int EOS = SpTokenizer::kBOS_EOS;  // 0
            const int PAD = SpTokenizer::kPAD;       // 65000
            const int ENC_MAXL = 128;

            // -- Step 1: Tokenize to shared vocab IDs --
            std::cerr << "[Translate] Step 1 encode begin, textLen="
                      << text.size() << std::endl;
            auto sharedIds = tokenizer_.encode(text);
            std::cerr << "[Translate] Step 1.1 encode done, tokenCount="
                      << sharedIds.size() << std::endl;
            if (sharedIds.empty()) return "";

            // ID range check
            {
                int minId = INT_MAX, maxId = INT_MIN;
                for (auto id : sharedIds) {
                    if (id < minId) minId = id;
                    if (id > maxId) maxId = id;
                }
                std::cerr << "[Translate] Step 1.2 ID range: min=" << minId
                          << " max=" << maxId
                          << " total=" << sharedIds.size() << std::endl;
            }

            // -- Build encoder inputs --
            std::vector<int64_t> inputIds(ENC_MAXL, PAD);
            std::vector<int64_t> attnMask(ENC_MAXL, 0);
            int copyLen = (std::min)(ENC_MAXL, (int)sharedIds.size());
            for (int i = 0; i < copyLen; i++) {
                inputIds[i] = (int64_t)sharedIds[i];
                attnMask[i] = 1;
            }

            auto memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

            // -- Step 2: Encoder Run --
            std::cerr << "[Translate] Step 2 encoder begin, realTokens="
                      << copyLen << std::endl;
            std::vector<Ort::Value> encIns;
            {
                int64_t dims[2] = {1, ENC_MAXL};
                encIns.push_back(Ort::Value::CreateTensor<int64_t>(
                    memInfo, inputIds.data(), ENC_MAXL, dims, 2));
            }
            if (encInNames_.size() > 1) {
                int64_t dims[2] = {1, ENC_MAXL};
                encIns.push_back(Ort::Value::CreateTensor<int64_t>(
                    memInfo, attnMask.data(), ENC_MAXL, dims, 2));
            }

            std::vector<const char*> eIn, eOut;
            for (auto& n : encInNames_) eIn.push_back(n.c_str());
            for (auto& n : encOutNames_) eOut.push_back(n.c_str());

            auto encOuts = encSession_->Run(Ort::RunOptions{nullptr},
                eIn.data(), encIns.data(), encIns.size(),
                eOut.data(), eOut.size());
            std::cerr << "[Translate] Step 2.1 encoder done, outputCount="
                      << encOuts.size() << std::endl;

            encData_.clear();
            encShapes_.clear();
            for (auto& eo : encOuts) {
                auto info = eo.GetTensorTypeAndShapeInfo();
                auto shape = info.GetShape();
                encShapes_.push_back(shape);
                size_t n = 1;
                for (auto d : shape) n *= (size_t)d;
                float* src = eo.GetTensorMutableData<float>();
                encData_.push_back(std::vector<float>(src, src + n));
            }

            // ═══════════════════════════════════════════════════════════════
            // Step 3: Autoregressive decoder (improved greedy)
            //
            // Decoding order per step:
            //   3a. Build decoder ONNX inputs
            //   3b. Extract logits + offset for last position
            //   3c. Repetition penalty (skip EOS/PAD/UNK)
            //   3d. No-repeat n-gram blocking (scan history, ban next-tokens)
            //   3e. EOS freeze window (first N steps forbid EOS)
            //   3f. Bad token suppression (PAD = -inf)
            //   3g. Argmax
            //   3h. PAD/UNK fallback → secondBest
            //   3i. Stop on EOS, else append + track tokenCount
            // ═══════════════════════════════════════════════════════════════
            const int DECODER_START = PAD;   // 65000
            const int MAXL = 128;

            // Tunable decoding parameters
            const float REPETITION_PENALTY = 1.2f;
            const int NO_REPEAT_NGRAM_SIZE = 3;
            const int EOS_FREEZE_STEPS = 4;    // forbid EOS in first 4 steps

            std::vector<int64_t> outIds = {DECODER_START};
            std::unordered_map<int, int> tokenCount;  // for repetition penalty

            std::cerr << "[Translate] Step 3 decoder loop begin"
                      << " DECODER_START=" << DECODER_START
                      << " EOS=" << EOS << " MAXL=" << MAXL
                      << " rep_penalty=" << REPETITION_PENALTY
                      << " no_repeat_ngram=" << NO_REPEAT_NGRAM_SIZE
                      << " eos_freeze=" << EOS_FREEZE_STEPS << std::endl;

            for (int step = 0; step < MAXL; step++) {
                // ── 3a. Build decoder ONNX inputs ──
                std::vector<Ort::Value> decIns;
                std::vector<const char*> dInPtrs;
                for (auto& n : decInNames_) dInPtrs.push_back(n.c_str());

                size_t encUsed = 0;

                for (size_t di = 0; di < decInNames_.size(); di++) {
                    const auto& name = decInNames_[di];
                    bool hasHidden   = name.find("hidden")   != std::string::npos;
                    bool hasAttention = name.find("attention") != std::string::npos;
                    bool hasInputIds  = name.find("input_ids") != std::string::npos;

                    if (hasInputIds) {
                        int64_t idCount = (int64_t)outIds.size();
                        int64_t idDims[2] = {1, idCount};
                        decIns.push_back(Ort::Value::CreateTensor<int64_t>(
                            memInfo, outIds.data(), (size_t)idCount, idDims, 2));
                    } else if (hasHidden && encUsed < encData_.size()) {
                        decIns.push_back(Ort::Value::CreateTensor<float>(
                            memInfo,
                            const_cast<float*>(encData_[encUsed].data()),
                            encData_[encUsed].size(),
                            encShapes_[encUsed].data(),
                            encShapes_[encUsed].size()));
                        encUsed++;
                    } else if (hasAttention) {
                        int64_t maskDims[2] = {1, ENC_MAXL};
                        decIns.push_back(Ort::Value::CreateTensor<int64_t>(
                            memInfo, attnMask.data(), (size_t)ENC_MAXL, maskDims, 2));
                    } else {
                        // Unexpected input -- feed a zero placeholder
                        int64_t zDims[2] = {1, 1};
                        int64_t zero = 0;
                        decIns.push_back(Ort::Value::CreateTensor<int64_t>(
                            memInfo, &zero, 1, zDims, 2));
                    }
                }

                std::vector<const char*> dOutPtrs;
                for (auto& n : decOutNames_) dOutPtrs.push_back(n.c_str());

                auto decOuts = decSession_->Run(Ort::RunOptions{nullptr},
                    dInPtrs.data(), decIns.data(), decIns.size(),
                    dOutPtrs.data(), dOutPtrs.size());

                // ── 3b. Extract logits for the LAST position ──
                float* logits = decOuts[0].GetTensorMutableData<float>();
                auto oShape = decOuts[0].GetTensorTypeAndShapeInfo().GetShape();
                size_t vsFull = oShape.back();  // 65001
                size_t offset = (oShape.size() >= 3)
                    ? (outIds.size() - 1) * vsFull
                    : 0;

                // ═════════════════════════════════════════════════════════
                // 3c. REPETITION PENALTY
                //
                // HuggingFace / fairseq formula:
                //   logits[v] < 0  →  logits[v] * penalty  (more negative)
                //   logits[v] >= 0 →  logits[v] / penalty  (less positive)
                //
                // Skip EOS, PAD, UNK -- penalizing EOS delays termination
                // and can cause degenerate repetition loops.
                // ═════════════════════════════════════════════════════════
                for (const auto& kv : tokenCount) {
                    int tid = kv.first;
                    if (tid == EOS || tid == PAD || tid == SpTokenizer::kUNK)
                        continue;
                    float& val = logits[offset + tid];
                    if (val < 0.0f) {
                        val *= REPETITION_PENALTY;
                    } else {
                        val /= REPETITION_PENALTY;
                    }
                }

                // ═════════════════════════════════════════════════════════
                // 3d. NO-REPEAT N-GRAM BLOCKING
                //
                // Algorithm:
                //   prefix = last (N-1) tokens of outIds.
                //   Scan outIds for every occurrence of prefix.
                //   For each match, collect the token that follows it.
                //   Ban all collected "next" tokens → logits = -inf.
                //
                // Example (N=3, outIds = [PAD, a, b, c, a, b]):
                //   prefix = [a, b]  (last 2 tokens)
                //   Match at outIds[1..2]=[a,b] → next=c  → ban c
                //   Match at outIds[4..5]=[a,b] → end, no next
                //
                // O(seq_len) history scan, no vocab iteration.
                // ═════════════════════════════════════════════════════════
                if (NO_REPEAT_NGRAM_SIZE > 1 &&
                    (int)outIds.size() >= NO_REPEAT_NGRAM_SIZE) {

                    int nMinus1 = NO_REPEAT_NGRAM_SIZE - 1;  // e.g. 2

                    // prefix = last (N-1) tokens
                    std::vector<int64_t> prefix(
                        outIds.end() - nMinus1, outIds.end());

                    // Scan history: find every position where prefix appears,
                    // collect the token that follows
                    std::unordered_set<int> bannedNext;
                    for (size_t i = 0; i + nMinus1 < outIds.size(); i++) {
                        bool match = true;
                        for (int k = 0; k < nMinus1; k++) {
                            if (outIds[i + k] != prefix[k]) {
                                match = false;
                                break;
                            }
                        }
                        if (match) {
                            // i + nMinus1 is guaranteed in-bounds by loop condition
                            int nextTok = (int)outIds[i + nMinus1];
                            if (nextTok != EOS && nextTok != PAD) {
                                bannedNext.insert(nextTok);
                            }
                        }
                    }

                    // Apply bans
                    for (int bt : bannedNext) {
                        logits[offset + bt] = -1e30f;
                    }

                    if (step < 8 && !bannedNext.empty()) {
                        std::cerr << "[Translate]   step " << step
                                  << " no_repeat banned=" << bannedNext.size()
                                  << " tokens" << std::endl;
                    }
                }

                // ═════════════════════════════════════════════════════════
                // 3e. EOS FREEZE WINDOW
                //
                // Forbid EOS in the first EOS_FREEZE_STEPS. The model often
                // assigns high probability to EOS before generating any
                // meaningful content, causing empty or very short output.
                // ═════════════════════════════════════════════════════════
                if (step < EOS_FREEZE_STEPS) {
                    logits[offset + EOS] = -1e30f;
                }

                // ═════════════════════════════════════════════════════════
                // 3f. BAD TOKEN SUPPRESSION
                //
                // PAD (65000): always forbidden (config.json bad_words_ids).
                // UNK (1): NOT suppressed — left reachable as last resort.
                //          The secondBest fallback at 3h will skip it if any
                //          better non-UNK token exists.
                // ═════════════════════════════════════════════════════════
                logits[offset + PAD] = -1e30f;

                // ═════════════════════════════════════════════════════════
                // 3g. ARGMAX
                // ═════════════════════════════════════════════════════════
                int nextTok = EOS;
                float best = -1e30f;
                for (size_t v = 0; v < vsFull; v++) {
                    if (logits[offset + v] > best) {
                        best = logits[offset + v];
                        nextTok = (int)v;
                    }
                }

                if (step < 8) {
                    std::cerr << "[Translate]   step " << step
                              << " argmax=" << nextTok
                              << " best=" << best
                              << " tokCounts=" << tokenCount.size()
                              << " outLen=" << outIds.size() << std::endl;
                }

                // ═════════════════════════════════════════════════════════
                // 3h. PAD / UNK FALLBACK
                //
                // If argmax picked PAD or UNK, find the next-best token
                // that is neither PAD nor UNK. Fall back to EOS only if
                // no other choice exists in the entire vocabulary.
                // ═════════════════════════════════════════════════════════
                if (nextTok == PAD || nextTok == SpTokenizer::kUNK) {
                    float secondBest = -1e30f;
                    int secondTok = EOS;
                    for (size_t v = 0; v < vsFull; v++) {
                        if ((int)v == PAD || (int)v == SpTokenizer::kUNK)
                            continue;
                        if (logits[offset + v] > secondBest) {
                            secondBest = logits[offset + v];
                            secondTok = (int)v;
                        }
                    }
                    nextTok = secondTok;
                    if (step < 8) {
                        std::cerr << "[Translate]   step " << step
                                  << " PAD/UNK suppressed → secondBest="
                                  << nextTok << std::endl;
                    }
                }

                // ═════════════════════════════════════════════════════════
                // 3i. STOP / APPEND
                // ═════════════════════════════════════════════════════════
                if (nextTok == EOS) {
                    if (step < 8) {
                        std::cerr << "[Translate]   step " << step
                                  << " → EOS, stopping" << std::endl;
                    }
                    break;
                }

                outIds.push_back(nextTok);
                tokenCount[nextTok]++;
            }
            std::cerr << "[Translate] Step 3.1 decoder loop end, outTokens="
                      << outIds.size() << std::endl;

            // -- Step 4: Decode with shared vocab --
            // Skip initial PAD, stop at EOS
            std::vector<int> decIds;
            for (size_t i = 1; i < outIds.size(); i++) {
                if (outIds[i] == EOS) break;
                decIds.push_back((int)outIds[i]);
            }
            std::string result = tokenizer_.decode(decIds);
            std::cerr << "[Translate] Step 4 done, resultLen="
                      << result.size() << " result=\"" << result << "\"" << std::endl;
            return result;

        } catch (const Ort::Exception& e) {
            std::cerr << "[Translate] Ort::Exception: " << e.what() << std::endl;
            return std::string("[err: ") + e.what() + "]";
        } catch (const std::exception& e) {
            std::cerr << "[Translate] std::exception: " << e.what() << std::endl;
            return std::string("[err: ") + e.what() + "]";
        } catch (...) {
            std::cerr << "[Translate] Unknown exception in Translate()" << std::endl;
            return "[err: unknown exception]";
        }
    }

private:
    // Accessor for logging -- tokenizer_ is private
    size_t idToPieceSize_() const {
        // Can't access private idToPiece_.size() directly.
        // Just return 0 here, actual count is logged inside SpTokenizer::Load.
        return 0;
    }

    SpTokenizer tokenizer_;
    std::unique_ptr<Ort::Env> env_;
    Ort::AllocatorWithDefaultOptions alloc_;
    std::unique_ptr<Ort::Session> encSession_;
    std::unique_ptr<Ort::Session> decSession_;
    std::vector<std::string> encInNames_, encOutNames_;
    std::vector<std::string> decInNames_, decOutNames_;
    std::vector<std::vector<float>> encData_;
    std::vector<std::vector<int64_t>> encShapes_;
    std::string modelDir_;
    bool initialized_ = false;
    std::string lastError_;
};

// ============================================================================
// Singleton
// ============================================================================

static std::unique_ptr<TranslateEngine> g_engine;
static std::once_flag g_flag;
static std::mutex g_mtx;

static std::string GetModelDir() {
    wchar_t exePath[MAX_PATH];
    std::string resolved;
    bool fromExe = false;
    if (GetModuleFileNameW(nullptr, exePath, MAX_PATH) > 0) {
        auto dir = std::filesystem::path(exePath).parent_path() / "models";
        if (std::filesystem::exists(dir)) {
            resolved = dir.string();
            std::replace(resolved.begin(), resolved.end(), '\\', '/');
            fromExe = true;
        }
    }
    if (resolved.empty()) {
        resolved = "models_translate";
    }
    std::cerr << "[Translate] GetModelDir: " << resolved
              << " (source=" << (fromExe ? "exe_dir" : "fallback") << ")" << std::endl;
    return resolved;
}

static TranslateEngine& GetEngine() {
    std::call_once(g_flag, []() {
        g_engine = std::make_unique<TranslateEngine>();
        std::string dir = GetModelDir();
        if (!g_engine->Initialize(dir)) {
            std::cerr << "[Translate] Init FAILED: " << g_engine->GetLastError() << std::endl;
        } else {
            std::cerr << "[Translate] Engine ready, model dir: " << dir << std::endl;
        }
    });
    return *g_engine;
}

// ============================================================================
// Per-text translate wrapper with logging
// ============================================================================

static std::string TranslateOneSafe(TranslateEngine& eng, const std::string& text, int index) {
    std::cerr << "[Translate] TranslateOneSafe text[" << index << "] begin, textLen="
              << text.size() << std::endl;
    std::string result = eng.Translate(text);
    std::cerr << "[Translate] TranslateOneSafe text[" << index << "] done, resultLen="
              << result.size() << std::endl;
    return result;
}

// ============================================================================
// Public API
// ============================================================================

std::string TranslateBatch(const std::string& jsonInput) {
    try {
        std::lock_guard<std::mutex> lock(g_mtx);

        auto pos = jsonInput.find("\"texts\"");
        if (pos == std::string::npos) {
            return "{\"ok\":false,\"error\":\"Missing 'texts' field\"}";
        }
        auto a0 = jsonInput.find('[', pos);
        auto a1 = jsonInput.find(']', a0);
        if (a0 == std::string::npos || a1 == std::string::npos) {
            return "{\"ok\":false,\"error\":\"Invalid 'texts' array\"}";
        }

        auto texts = parseJsonStringArray(jsonInput.substr(a0, a1 - a0 + 1));

        std::cerr << "[Translate] TranslateBatch: " << texts.size() << " texts" << std::endl;
        for (size_t i = 0; i < texts.size() && i < 5; i++) {
            std::string preview = texts[i].size() > 80
                ? texts[i].substr(0, 80) + "..."
                : texts[i];
            std::cerr << "[Translate]   text[" << i << "] len=" << texts[i].size()
                      << " \"" << preview << "\"" << std::endl;
        }

        auto& eng = GetEngine();

        std::ostringstream js;
        js << "{\"ok\":true,\"translations\":[";
        for (size_t i = 0; i < texts.size(); i++) {
            if (i) js << ",";
            std::string translated = TranslateOneSafe(eng, texts[i], (int)i);
            js << "\"" << esc(translated) << "\"";
        }
        js << "],\"diag\":{"
           << "\"model_loaded\":" << (eng.IsInitialized() ? "true" : "false")
           << ",\"count\":" << texts.size()
           << "}}";
        return js.str();

    } catch (const std::exception& e) {
        std::cerr << "[Translate] TranslateBatch CATCH(std): " << e.what() << std::endl;
        std::ostringstream js;
        js << "{\"ok\":false,\"error\":\"TranslateBatch exception: "
           << esc(e.what()) << "\"}";
        return js.str();
    } catch (...) {
        std::cerr << "[Translate] TranslateBatch CATCH(...): unknown exception" << std::endl;
        return "{\"ok\":false,\"error\":\"TranslateBatch: unknown exception\"}";
    }
}
