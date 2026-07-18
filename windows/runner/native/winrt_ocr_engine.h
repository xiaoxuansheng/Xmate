// XMate - WinRT OCR engine (Windows.Media.Ocr backend)
// Used for English / Latin-script recognition.
#pragma once

#include <string>
#include <vector>
#include <cstdint>

/// Run OCR on a PNG image using Windows.Media.Ocr, returning JSON.
///
/// @param pngBytes  Raw PNG file bytes.
/// @param cropX, cropY  Pixel offset of this crop within the original image.
///                      Added to every quad point / block rect so output
///                      coordinates are in original-image space.
/// @param language  BCP-47 language tag, e.g. "en", "en-US". Default "en".
/// @return JSON string matching the existing PP-OCRv6 output protocol.
std::string WinRTOcrFromPNG(const std::vector<uint8_t>& pngBytes,
                            int cropX = 0, int cropY = 0,
                            const std::string& language = "en");
