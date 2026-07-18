// XMate Indexer Service — shared config file (read by both Service and GUI).
#pragma once

#include <string>
#include <vector>

struct IndexerConfig {
  std::vector<std::string> paths;   // root paths to monitor
  int intervalSec = 60;             // USN polling interval
};

/// Read config from %ProgramData%\XMate\index_config.json.
/// Returns default (empty paths, 60s) if file doesn't exist.
IndexerConfig LoadIndexerConfig();

/// Write config to %ProgramData%\XMate\index_config.json.
/// Creates %ProgramData%\XMate\ if missing.
bool SaveIndexerConfig(const IndexerConfig& cfg);

/// Get the directory where index results are stored
///   (under %ProgramData%\XMate\index_results)
std::wstring GetIndexerResultsDir();

/// Get the full path to the config file:
///   %ProgramData%\XMate\index_config.json
std::wstring GetIndexerConfigPath();
