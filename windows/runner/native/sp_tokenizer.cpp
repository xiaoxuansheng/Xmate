// XMate - Shared vocabulary tokenizer with true BPE merge (matching SP)
#include "sp_tokenizer.h"

#include <windows.h>
#include <algorithm>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

// ============================================================================
// NFKC normalization
// ============================================================================

static std::string nfkcNormalize(const std::string& s) {
    if (s.empty()) return s;
    int wlen = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    if (wlen <= 0) return s;
    std::wstring ws(wlen, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &ws[0], wlen);

    int normLen = NormalizeString(NormalizationKC, ws.c_str(), (int)ws.size(), nullptr, 0);
    if (normLen <= 0) return s;
    std::wstring norm(normLen, L'\0');
    NormalizeString(NormalizationKC, ws.c_str(), (int)ws.size(), &norm[0], normLen);

    int u8len = WideCharToMultiByte(CP_UTF8, 0, norm.c_str(), (int)norm.size(), nullptr, 0, nullptr, nullptr);
    if (u8len <= 0) return s;
    std::string result(u8len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, norm.c_str(), (int)norm.size(), &result[0], u8len, nullptr, nullptr);
    return result;
}

// ============================================================================
// SpTokenizer
// ============================================================================

bool SpTokenizer::Load(const std::string& modelDir) {
    std::string path = modelDir + "/shared_vocab.txt";
    std::ifstream f(path);
    if (!f.is_open()) {
        lastError_ = "shared_vocab.txt not found in " + modelDir;
        return false;
    }

    int maxId = -1;
    std::string line;
    while (std::getline(f, line)) {
        while (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;

        // Parse: shared_id<TAB>piece<TAB>score
        size_t tab1 = line.find('\t');
        if (tab1 == std::string::npos) continue;
        size_t tab2 = line.find('\t', tab1 + 1);
        if (tab2 == std::string::npos) continue;

        int id = std::stoi(line.substr(0, tab1));
        std::string piece = line.substr(tab1 + 1, tab2 - tab1 - 1);
        float score = std::stof(line.substr(tab2 + 1));

        if (id > maxId) maxId = id;
        idToPiece_[id] = piece;
        pieceToId_[piece] = id;
        pieceScore_[piece] = score;
    }
    f.close();

    if (maxId < 0) {
        lastError_ = "shared_vocab.txt was empty";
        return false;
    }

    std::cerr << "[Translate] Shared vocab loaded: " << pieceToId_.size()
              << " entries, maxId=" << maxId
              << " BOS/EOS=" << kBOS_EOS << " UNK=" << kUNK << " PAD=" << kPAD
              << std::endl;

    initialized_ = true;
    return true;
}

bool SpTokenizer::IsInitialized() const { return initialized_; }
std::string SpTokenizer::GetLastError() const { return lastError_; }

std::vector<int> SpTokenizer::encode(const std::string& text) const {
    if (!initialized_) return {kBOS_EOS};

    // 1. NFKC normalize (case-sensitive)
    std::string norm = nfkcNormalize(text);

    // 2. Split by whitespace only
    std::vector<std::string> segments;
    std::string cur;
    for (size_t i = 0; i < norm.size(); i++) {
        char c = norm[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!cur.empty()) { segments.push_back(cur); cur.clear(); }
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) segments.push_back(cur);

    // 3. U+2581 prefix
    std::string SM;
    SM += '\xE2'; SM += '\x96'; SM += '\x81';

    // Helper: get UTF-8 character length from lead byte
    auto utf8CharLen = [](unsigned char lead) -> int {
        if (lead < 0x80) return 1;
        if (lead < 0xE0) return 2;
        if (lead < 0xF0) return 3;
        return 4;
    };

    std::vector<int> ids;

    for (const auto& seg : segments) {
        std::string s = SM + seg;

        // Build character-position byte offsets
        std::vector<size_t> cpos;
        size_t pos = 0;
        while (pos < s.size()) {
            cpos.push_back(pos);
            pos += utf8CharLen((unsigned char)s[pos]);
        }
        cpos.push_back(pos);  // end position
        int n = (int)cpos.size() - 1;  // number of characters

        // Viterbi: find optimal tokenization
        // bestScore[i] = max total score for prefix ending at character i
        const float NEG_INF = -1e30f;
        std::vector<float> bestScore(n + 1, NEG_INF);
        std::vector<int> bestPrev(n + 1, -1);
        std::vector<int> bestTok(n + 1, -1);
        bestScore[0] = 0.0f;

        const int MAX_TOK_CHARS = 32;

        for (int i = 0; i < n; i++) {
            if (bestScore[i] <= NEG_INF * 0.5f) continue;
            for (int j = i + 1; j <= n && j - i <= MAX_TOK_CHARS; j++) {
                std::string piece = s.substr(cpos[i], cpos[j] - cpos[i]);
                auto it = pieceScore_.find(piece);
                // Skip pieces with score >= 0: these are target-only tokens
                // (not in source SP) or special tokens. Real SP tokens have
                // negative log-probability scores.
                if (it != pieceScore_.end() && it->second < -0.0001f) {
                    float score = bestScore[i] + it->second;
                    if (score > bestScore[j]) {
                        bestScore[j] = score;
                        bestPrev[j] = i;
                        auto idIt = pieceToId_.find(piece);
                        bestTok[j] = (idIt != pieceToId_.end()) ? idIt->second : kUNK;
                    }
                }
            }
            // SP unigram: if no single-char token at position i, insert UNK
            // (All single chars exist in our shared vocab, so this is rare.)
            if (bestScore[i] > NEG_INF * 0.5f && bestScore[i+1] <= NEG_INF * 0.5f) {
                // Check if single-char token exists
                std::string ch = s.substr(cpos[i], cpos[i+1] - cpos[i]);
                if (pieceScore_.count(ch)) {
                    float score = bestScore[i] + pieceScore_.at(ch);
                    if (score > bestScore[i+1]) {
                        bestScore[i+1] = score;
                        bestPrev[i+1] = i;
                        bestTok[i+1] = pieceToId_.at(ch);
                    }
                } else {
                    // UNK fallback with very low score (matching SP's
                    // unk_score = min_score - kUnkPenalty)
                    bestScore[i+1] = bestScore[i] - 20.0f;
                    bestPrev[i+1] = i;
                    bestTok[i+1] = kUNK;
                }
            }
        }

        // Backtrack
        std::vector<int> tokIds;
        int p = n;
        while (p > 0) {
            tokIds.push_back(bestTok[p]);
            p = bestPrev[p];
        }
        std::reverse(tokIds.begin(), tokIds.end());
        for (int tid : tokIds) ids.push_back(tid);
    }

    // 4. Append EOS
    ids.push_back(kBOS_EOS);
    return ids;
}

std::string SpTokenizer::decode(const std::vector<int>& ids) const {
    if (!initialized_) return "";

    std::string result;
    for (int id : ids) {
        if (id == kPAD) continue;
        if (id == kBOS_EOS) break;
        auto it = idToPiece_.find(id);
        if (it == idToPiece_.end()) continue;
        const std::string& piece = it->second;
        for (size_t j = 0; j < piece.size(); ) {
            if ((unsigned char)piece[j] == 0xE2 && j+2 < piece.size() &&
                (unsigned char)piece[j+1] == 0x96 && (unsigned char)piece[j+2] == 0x81) {
                result += ' ';
                j += 3;
            } else {
                result += piece[j];
                j++;
            }
        }
    }
    return result;
}
