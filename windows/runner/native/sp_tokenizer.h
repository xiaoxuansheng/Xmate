// XMate - Shared vocabulary tokenizer for OPUS-MT MarianMT
//
// Loads shared_vocab.txt (shared_id<TAB>piece<TAB>score).
// encode() implements SentencePiece Unigram tokenization:
//   character-level token lattice + Viterbi optimal-path decoding,
//   matching official SentencePiece output exactly.
//
// Special token IDs (from model config.json):
//   0     = </s>  (BOS / EOS)
//   1     = <unk>
//   65000 = <pad>

#pragma once

#include <string>
#include <unordered_map>
#include <vector>
#include <cstdint>

struct SpTokenizer {
    static constexpr int kBOS_EOS = 0;
    static constexpr int kUNK    = 1;
    static constexpr int kPAD    = 65000;

    bool Load(const std::string& modelDir);
    bool IsInitialized() const;
    std::string GetLastError() const;

    // Encode English text to shared vocab IDs using true BPE merge.
    // Includes EOS at the end.
    std::vector<int> encode(const std::string& text) const;

    // Decode shared vocab IDs to text.
    std::string decode(const std::vector<int>& ids) const;

private:
    // shared_id -> piece
    std::unordered_map<int, std::string> idToPiece_;
    // piece -> shared_id
    std::unordered_map<std::string, int> pieceToId_;
    // piece -> SP merge score (for BPE agenda ordering)
    std::unordered_map<std::string, float> pieceScore_;

    bool initialized_ = false;
    std::string lastError_;
};
