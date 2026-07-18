// XMate - Offline EN->ZH translation engine (UTF-8 BOM)
//
// Uses ONNX Runtime for inference, same infrastructure as OCR.
// Model: OPUS-MT en-zh (MarianMT) exported to ONNX.
// Tokenizer: inline BPE (no external deps).
//
// Input:  JSON  {"texts":["hello","world"],"from":"en","to":"zh"}
// Output: JSON  {"ok":true,"translations":["...","..."]}
//         or   {"ok":false,"error":"..."}

#pragma once

#include <string>
#include <vector>
#include <cstdint>

/// Batch-translate multiple texts from the source language to the target language.
/// [jsonInput] is a JSON object: {"texts":[...], "from":"en", "to":"zh"}
/// Returns JSON: {"ok":true,"translations":[...]} or {"ok":false,"error":"..."}
std::string TranslateBatch(const std::string& jsonInput);
