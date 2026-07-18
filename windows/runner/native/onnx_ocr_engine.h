// XMate - PaddleOCR ONNX Runtime engine
#pragma once

#include <string>
#include <vector>
#include <cstdint>

/// Run OCR on a PNG image, returning JSON.
/// Same API as the old WinRT OcrFromPNG — drop-in replacement.
std::string OcrFromPNG(const std::vector<uint8_t>& pngBytes);

/// Extended entry point with crop offset and optional UVDoc unwarping.
std::string OcrFromPNGWithOffset(const std::vector<uint8_t>& pngBytes,
                                 int cropX, int cropY, bool enableUnwarp);
