// XMate - GPT-2 Byte-Level BPE tokenizer for OCR word boundary recovery
//
// Loads gpt2_vocab.json (50,257 tokens) and gpt2_merges.txt (50,000 merges).
// Implements Viterbi DP word segmentation using GPT-2 vocabulary as dictionary.

#include "gpt2_bpe_tokenizer.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>

// ============================================================================
// Minimal JSON parser -- only handles {"string":int, ...} objects
// ============================================================================

namespace {

// Read a JSON string token (handles \", \\, \/, \b, \f, \n, \r, \t, \uXXXX).
std::string readJsonString(const char*& p, const char* end) {
    if (p >= end || *p != '"') return "";
    p++;
    std::string out;
    out.reserve(64);
    while (p < end && *p != '"') {
        if (*p == '\\') {
            p++;
            if (p >= end) return "";
            switch (*p) {
                case '"':  out += '"';  p++; break;
                case '\\': out += '\\'; p++; break;
                case '/':  out += '/';  p++; break;
                case 'b':  out += '\b'; p++; break;
                case 'f':  out += '\f'; p++; break;
                case 'n':  out += '\n'; p++; break;
                case 'r':  out += '\r'; p++; break;
                case 't':  out += '\t'; p++; break;
                case 'u': {
                    p++;
                    if (p + 4 > end) return "";
                    char hex[5] = {p[0], p[1], p[2], p[3], '\0'};
                    unsigned cp = 0;
                    for (int i = 0; i < 4; i++) {
                        cp <<= 4;
                        char c = hex[i];
                        if (c >= '0' && c <= '9') cp |= (c - '0');
                        else if (c >= 'a' && c <= 'f') cp |= (c - 'a' + 10);
                        else if (c >= 'A' && c <= 'F') cp |= (c - 'A' + 10);
                        else return "";
                    }
                    if (cp < 0x80) {
                        out += (char)cp;
                    } else if (cp < 0x800) {
                        out += (char)(0xC0 | (cp >> 6));
                        out += (char)(0x80 | (cp & 0x3F));
                    } else if (cp < 0x10000) {
                        out += (char)(0xE0 | (cp >> 12));
                        out += (char)(0x80 | ((cp >> 6) & 0x3F));
                        out += (char)(0x80 | (cp & 0x3F));
                    } else {
                        cp -= 0x10000;
                        out += (char)(0xF0 | (cp >> 18));
                        out += (char)(0x80 | ((cp >> 12) & 0x3F));
                        out += (char)(0x80 | ((cp >> 6) & 0x3F));
                        out += (char)(0x80 | (cp & 0x3F));
                    }
                    p += 4;
                    break;
                }
                default: return "";
            }
        } else {
            out += *p;
            p++;
        }
    }
    if (p < end && *p == '"') p++;
    return out;
}

void skipWs(const char*& p, const char* end) {
    while (p < end && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
}

int readInt(const char*& p, const char* end) {
    int val = 0;
    while (p < end && *p >= '0' && *p <= '9') {
        val = val * 10 + (*p - '0');
        p++;
    }
    return val;
}

}  // anonymous namespace

// ============================================================================
// Gpt2BpeTokenizer -- public API
// ============================================================================

bool Gpt2BpeTokenizer::Load(const std::string& modelDir) {
    // -- Load vocab.json --------------------------------------------------
    {
        std::string path = modelDir + "/gpt2_vocab.json";
        std::ifstream f(path, std::ios::binary);
        if (!f.is_open()) {
            lastError_ = "gpt2_vocab.json not found in " + modelDir;
            return false;
        }
        std::string raw((std::istreambuf_iterator<char>(f)),
                        std::istreambuf_iterator<char>());
        f.close();

        const char* p = raw.data();
        const char* end = p + raw.size();

        skipWs(p, end);
        if (p >= end || *p != '{') {
            lastError_ = "gpt2_vocab.json: expected '{' at start";
            return false;
        }
        p++;

        tokenToId_.reserve(51000);
        idToToken_.reserve(51000);

        while (true) {
            skipWs(p, end);
            if (p >= end) break;
            if (*p == '}') { p++; break; }

            std::string key = readJsonString(p, end);
            if (key.empty() && !(p < end && *p == '}')) {
                lastError_ = "gpt2_vocab.json: failed to parse string key";
                return false;
            }
            if (key.empty()) break;

            skipWs(p, end);
            if (p >= end || *p != ':') {
                lastError_ = "gpt2_vocab.json: expected ':' after key";
                return false;
            }
            p++;

            skipWs(p, end);
            int id = readInt(p, end);

            tokenToId_[key] = id;
            idToToken_[id] = key;

            skipWs(p, end);
            if (p < end && *p == ',') p++;
        }

        if (tokenToId_.empty()) {
            lastError_ = "gpt2_vocab.json: no entries parsed";
            return false;
        }
    }

    // -- Load merges.txt --------------------------------------------------
    {
        std::string path = modelDir + "/gpt2_merges.txt";
        std::ifstream f(path, std::ios::binary);
        if (!f.is_open()) {
            lastError_ = "gpt2_merges.txt not found in " + modelDir;
            return false;
        }

        mergeRank_.reserve(51000);

        std::string line;
        while (std::getline(f, line)) {
            while (!line.empty() && (line.back() == '\r' || line.back() == '\n'))
                line.pop_back();
            if (line.empty()) continue;
            if (line[0] == '#') continue;

            size_t sp = line.find(' ');
            if (sp == std::string::npos || sp + 1 >= line.size()) continue;

            std::string left = line.substr(0, sp);
            std::string right = line.substr(sp + 1);
            if (left.empty() || right.empty()) continue;

            std::string key;
            key.reserve(left.size() + 1 + right.size());
            key += left;
            key += '\0';
            key += right;
            int rank = (int)mergeRank_.size();
            if (mergeRank_.find(key) == mergeRank_.end()) {
                mergeRank_[std::move(key)] = rank;
            }
        }
        f.close();
    }

    // -- Build wordCost_ dictionary from GPT-2 vocab ----------------------
    // Only include G-prefixed tokens (U+0120 = 0xC4 0xA0 in UTF-8).
    // G-prefix means the token appears at word-starts in GPT-2 training data.
    //
    // Cost tiers (all-known-only DP: unknown segments are NOT allowed):
    //   len >= 4  : cost = 2  (long words: cheap, encourage splitting here)
    //   len 2-3   : cost = 8  (short words: expensive, discourage fragmentation)
    //   "a", "i"  : cost = 8  (single-letter English words)
    {
        const std::string G_PREFIX = "\xC4\xA0";
        wordCost_.reserve(21000);

        for (const auto& kv : tokenToId_) {
            const std::string& token = kv.first;

            // Only G-prefixed tokens
            if (token.size() < 4) continue;
            if ((unsigned char)token[0] != 0xC4 ||
                (unsigned char)token[1] != 0xA0) continue;

            std::string core = token.substr(2);

            // Core must be pure [a-z]{2,}
            bool allLower = true;
            for (size_t i = 0; i < core.size(); i++) {
                if (core[i] < 'a' || core[i] > 'z') { allLower = false; break; }
            }
            if (!allLower) continue;

            // Assign cost by length + frequency (lower ID = more common)
            //   4+ chars     = 2  (cheap, long words are strong anchors)
            //   2 chars      = 8
            //   3 chars: common (G-id < 1000) = 6, rare = 16
            //   "a" / "i"    = 8
            int cost;
            if (core.size() >= 4) {
                cost = 2;
            } else if (core.size() == 2) {
                cost = 8;
            } else {
                // 3-char: common words cheaper than being split
                int gid = kv.second;
                cost = (gid < 1000) ? 6 : 16;
            }

            // Keep the lower cost if already present
            auto it = wordCost_.find(core);
            if (it == wordCost_.end() || cost < it->second) {
                wordCost_[core] = cost;
            }
        }

        // Single-letter English words
        wordCost_["a"] = 8;
        wordCost_["i"] = 8;
    }

    std::cerr << "[GPT2-BPE] Loaded: " << tokenToId_.size() << " vocab entries"
              << ", " << mergeRank_.size() << " merge rules"
              << ", " << wordCost_.size() << " known words"
              << std::endl;

    initialized_ = true;
    return true;
}

bool Gpt2BpeTokenizer::IsInitialized() const { return initialized_; }
std::string Gpt2BpeTokenizer::GetLastError() const { return lastError_; }

bool Gpt2BpeTokenizer::isKnown(const std::string& token) const {
    return wordCost_.find(token) != wordCost_.end();
}

std::vector<std::string> Gpt2BpeTokenizer::segment(const std::string& text) const {
    if (!initialized_ || text.empty()) return {text};

    // Guard: input must be [a-z]+ only
    for (size_t i = 0; i < text.size(); i++) {
        if (text[i] < 'a' || text[i] > 'z') return {text};
    }

    const int n = (int)text.size();
    const int MAX_WORD_LEN = 24;

    // ── Pass 1: all-known DP (preferred) ─────────────────────────────
    std::vector<int> dp(n + 1, std::numeric_limits<int>::max());
    std::vector<int> prev(n + 1, -1);
    dp[0] = 0;

    for (int i = 0; i < n; i++) {
        if (dp[i] == std::numeric_limits<int>::max()) continue;
        int maxJ = std::min(n, i + MAX_WORD_LEN);
        for (int j = i + 1; j <= maxJ; j++) {
            std::string word = text.substr(i, j - i);
            auto it = wordCost_.find(word);
            if (it == wordCost_.end()) continue;

            int newCost = dp[i] + it->second;
            if (newCost < dp[j]) {
                dp[j] = newCost;
                prev[j] = i;
            } else if (newCost == dp[j]) {
                if ((j - i) < (j - prev[j])) {
                    dp[j] = newCost;
                    prev[j] = i;
                }
            }
        }
    }

    // No path at all → return unchanged
    if (dp[n] == std::numeric_limits<int>::max()) return {text};

    // Backtrack
    std::vector<std::string> words;
    int pos = n;
    while (pos > 0) {
        int p = prev[pos];
        if (p < 0) return {text};
        words.push_back(text.substr(p, pos - p));
        pos = p;
    }
    std::reverse(words.begin(), words.end());
    return words;
}

// ============================================================================
// Self-test (compile with -DGPT2_BPE_SELF_TEST)
// ============================================================================

#ifdef GPT2_BPE_SELF_TEST

#include <cstdio>

static void RunSelfTest() {
    std::string modelDir = "windows/runner/native/models";

    Gpt2BpeTokenizer tok;
    if (!tok.Load(modelDir)) {
        printf("GPT2_BPE_SELF_TEST: SKIP -- %s\n", tok.GetLastError().c_str());
        return;
    }
    printf("GPT2_BPE_SELF_TEST: tokenizer loaded OK\n");

    auto test = [&](const std::string& input,
                    const std::vector<std::string>& expected) {
        auto result = tok.segment(input);
        bool pass = (result == expected);
        printf("  '%s' -> [", input.c_str());
        for (size_t i = 0; i < result.size(); i++) {
            if (i > 0) printf(" ");
            printf("'%s'", result[i].c_str());
        }
        printf("]  %s\n", pass ? "PASS" : "FAIL");
        if (!pass) {
            printf("    expected: [");
            for (size_t i = 0; i < expected.size(); i++) {
                if (i > 0) printf(" ");
                printf("'%s'", expected[i].c_str());
            }
            printf("]\n");
        }
    };

    printf("--- Word segmentations ---\n");
    test("thisisatest", {"this", "is", "a", "test"});
    test("helloworld", {"hello", "world"});
    test("thequickbrownfox", {"the", "quick", "brown", "fox"});
    test("filedownload", {"file", "download"});
    test("iam", {"i", "am"});
    test("isa", {"is", "a"});

    printf("--- Should stay whole (no all-known path) ---\n");
    test("tokenizer", {"tokenizer"});
    test("string", {"string"});
    test("version", {"version"});
    test("username", {"username"});

    printf("--- Non-[a-z] guard ---\n");
    {
        auto r = tok.segment("hello world");
        printf("  'hello world' -> %zu tokens (guard: %s)\n",
               r.size(), r.size() == 1 ? "PASS" : "FAIL");
    }

    printf("--- isKnown checks ---\n");
    printf("  isKnown('this'):   %s\n", tok.isKnown("this")   ? "PASS" : "FAIL");
    printf("  isKnown('hello'):  %s\n", tok.isKnown("hello")  ? "PASS" : "FAIL");
    printf("  isKnown('a'):      %s\n", tok.isKnown("a")      ? "PASS" : "FAIL");
    printf("  isKnown('tok'):    %s\n", tok.isKnown("tok")    ? "FAIL (fragment)" : "PASS");

    printf("\nGPT2_BPE_SELF_TEST: complete.\n");
}

struct SelfTestRunner {
    SelfTestRunner() { RunSelfTest(); }
};
static SelfTestRunner runner;

#endif  // GPT2_BPE_SELF_TEST
