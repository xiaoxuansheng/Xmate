// XMate - GPT-2 Byte-Level BPE tokenizer for OCR word boundary recovery
//
// Loads gpt2_vocab.json (50,257 tokens) and gpt2_merges.txt (50,000 merges).
// Uses GPT-2 vocabulary as a known-word dictionary for Viterbi DP word
// segmentation of concatenated lowercase English text.
//
// This is NOT a general-purpose tokenizer. It only supports [a-z]+ input.
// CJK characters, uppercase, digits, and punctuation are handled by the
// caller (ApplyBpeSegmentation) and should never reach segment().

#pragma once

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cstdint>

struct Gpt2BpeTokenizer {
    bool Load(const std::string& modelDir);
    bool IsInitialized() const;
    std::string GetLastError() const;

    /// Segment a lowercase ASCII letter run into known English words using
    /// Viterbi DP. Only paths where EVERY segment is a known word are valid.
    /// If no all-known path exists, returns [text] unchanged.
    ///
    /// Cost function:
    ///   - len >= 4 known word : cost = 2
    ///   - len 2-3 known word  : cost = 8  (higher cost for short words)
    ///   - "a" / "i"           : cost = 8
    ///   - unknown segment     : not allowed (no path)
    ///
    /// Tiebreaker: when equal-cost paths exist, shorter word at the boundary
    /// is preferred (leaves more chars for the rest of the sequence).
    ///
    /// Examples:
    ///   "thisisatest" -> ["this", "is", "a", "test"]
    ///   "helloworld"  -> ["hello", "world"]
    ///   "tokenizer"   -> ["tokenizer"]  (no all-known path fragments it)
    std::vector<std::string> segment(const std::string& text) const;

    /// Check whether a token is in the known-words dictionary.
    bool isKnown(const std::string& token) const;

private:
    // token string -> integer ID (from vocab.json)
    std::unordered_map<std::string, int> tokenToId_;
    // integer ID -> token string
    std::unordered_map<int, std::string> idToToken_;

    // Known word -> DP cost
    //   len >= 4: 2, len 2-3: 8, "a"/"i": 8
    std::unordered_map<std::string, int> wordCost_;

    // BPE merge rank (loaded but not currently used; available for future tuning)
    std::unordered_map<std::string, int> mergeRank_;

    bool initialized_ = false;
    std::string lastError_;
};
