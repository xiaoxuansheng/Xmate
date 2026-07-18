cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "native/folder_picker.cpp"
  "native/pin_window.cpp"
  "native/annotation_overlay.cpp"
  "native/screenshot_capture.cpp"
  "native/tray_icon.cpp"
  "native/ocr_engine.cpp"
  "native/onnx_ocr_engine.cpp"
  "native/winrt_ocr_engine.cpp"
  "native/translate_engine.cpp"
  "native/file_scanner.cpp"
  "native/usn_journal.cpp"
  "native/file_operations.cpp"
  "native/indexer_config.cpp"
  "native/indexer_service.cpp"
  "native/debug_tools.cpp"
  "native/drag_drop_handler.cpp"
  "native/quicklook_helper.cpp"
  "native/screenrecording_channel.cpp"
  "native/keyboard_hook.cpp"
  "native/monitor_swap.cpp"
  "native/office_preview_handler.cpp"
  "native/sp_tokenizer.cpp"
  "native/gpt2_bpe_tokenizer.cpp"
  "native/third_party/stb_impl.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# onnx_ocr_engine.cpp uses ONNX Runtime C++ API which requires exceptions
# (overriding the project-wide _HAS_EXCEPTIONS=0 from Flutter template).
# No more C++/WinRT quirks needed — plain C++17.
set_source_files_properties(native/office_preview_handler.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /EHsc")
set_source_files_properties(native/onnx_ocr_engine.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /D_CRT_SECURE_NO_WARNINGS /EHsc")
set_source_files_properties(native/translate_engine.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /D_CRT_SECURE_NO_WARNINGS /EHa /wd4244")
set_source_files_properties(native/sp_tokenizer.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /D_CRT_SECURE_NO_WARNINGS /EHa")
set_source_files_properties(native/gpt2_bpe_tokenizer.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /D_CRT_SECURE_NO_WARNINGS /EHa")
set_source_files_properties(native/winrt_ocr_engine.cpp PROPERTIES
    COMPILE_FLAGS "/U_HAS_EXCEPTIONS /D_HAS_EXCEPTIONS=1 /EHsc /bigobj /wd4819")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "comctl32.lib" "dwmapi.lib" "gdiplus.lib" "shell32.lib" "ole32.lib" "taskschd.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "WindowsApp.lib")

# --- ONNX Runtime ---
set(ONNXRUNTIME_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/native/third_party/onnxruntime")

# C++/WinRT headers (shipped with Windows SDK, no NuGet needed)
# Try env vars first, then fall back to known install locations.
if(DEFINED ENV{WindowsSdkDir} AND NOT "$ENV{WindowsSdkDir}" STREQUAL "")
  file(TO_CMAKE_PATH "$ENV{WindowsSdkDir}Include/$ENV{WindowsSDKVersion}cppwinrt" WINRT_INCLUDE_DIR)
elseif(EXISTS "C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/cppwinrt")
  set(WINRT_INCLUDE_DIR "C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/cppwinrt")
else()
  # Wildcard: pick the latest installed SDK version
  file(GLOB _sdk_versions LIST_DIRECTORIES true
       "C:/Program Files (x86)/Windows Kits/10/Include/10.*")
  if(_sdk_versions)
    list(GET _sdk_versions -1 _latest)
    set(WINRT_INCLUDE_DIR "${_latest}/cppwinrt")
  endif()
endif()

target_include_directories(${BINARY_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/.."
    "${ONNXRUNTIME_ROOT}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/native/third_party"
    "${WINRT_INCLUDE_DIR}"
)
target_link_libraries(${BINARY_NAME} PRIVATE
    "${ONNXRUNTIME_ROOT}/lib/onnxruntime.lib"
    delayimp)
target_link_options(${BINARY_NAME} PRIVATE "/DELAYLOAD:onnxruntime.dll")

# ── POST_BUILD: copy runtime assets to output directory ──────────────
# These run every flutter build so the Release folder is always complete.

# 7za.exe — archive preview (7z/RAR/...)
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/7za.exe"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/7za.exe"
  COMMENT "Copying 7za.exe → output"
)

# ONNX Runtime DLL
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${ONNXRUNTIME_ROOT}/lib/onnxruntime.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/onnxruntime.dll"
  COMMENT "Copying onnxruntime.dll → output"
)

# OCR / translation models (exclude sealed MarianMT 553MB)
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/PP-OCRv6_small_det.onnx"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/PP-OCRv6_small_det.onnx"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/PP-OCRv6_small_rec.onnx"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/PP-OCRv6_small_rec.onnx"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/doc_orientation.onnx"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/doc_orientation.onnx"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/text_unwarping.onnx"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/text_unwarping.onnx"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/textline_orientation.onnx"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/textline_orientation.onnx"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/ppocrv6_dict.txt"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/ppocrv6_dict.txt"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/ppocrv6_rec_config.yml"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/ppocrv6_rec_config.yml"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/config.json"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/config.json"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/gpt2_merges.txt"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/gpt2_merges.txt"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/native/models/gpt2_vocab.json"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/models/gpt2_vocab.json"
  COMMENT "Copying OCR models → output/models/"
)

# LibreTranslate scripts
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/scripts/minisbd"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/translate_model_manager.py"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/scripts/translate_model_manager.py"
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/minisbd"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/scripts/minisbd"
  COMMENT "Copying LibreTranslate scripts → output/scripts/"
)

# FFmpeg — screen recording
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_CURRENT_SOURCE_DIR}/../../tools/ffmpeg.exe"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/ffmpeg.exe"
  COMMENT "Copying ffmpeg.exe → output"
)

# qpdf — PDF post-processing (bundled exe + dll + MinGW runtime)
set(QPDF_DIR "${CMAKE_CURRENT_SOURCE_DIR}/native/third_party/qpdf")
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${QPDF_DIR}/qpdf.exe"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/qpdf.exe"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${QPDF_DIR}/qpdf30.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/qpdf30.dll"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${QPDF_DIR}/libgcc_s_seh-1.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/libgcc_s_seh-1.dll"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${QPDF_DIR}/libstdc++-6.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/libstdc++-6.dll"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${QPDF_DIR}/libwinpthread-1.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/libwinpthread-1.dll"
  COMMENT "Copying qpdf + MinGW runtime → output"
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# --- Install rules (for cmake --install, used by CI) ---
install(FILES "${ONNXRUNTIME_ROOT}/lib/onnxruntime.dll"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/native/models/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/models" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/native/7za.exe"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/translate_model_manager.py"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/scripts" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../../scripts/minisbd/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/scripts/minisbd" COMPONENT Runtime)
install(FILES "${QPDF_DIR}/qpdf.exe"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${QPDF_DIR}/qpdf30.dll"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${QPDF_DIR}/libgcc_s_seh-1.dll"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${QPDF_DIR}/libstdc++-6.dll"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${QPDF_DIR}/libwinpthread-1.dll"
    DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
