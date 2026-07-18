#pragma once
#include <string>

/// Query the active Explorer window for the selected file via COM IShellWindows.
/// Returns JSON string: {"path": "<full_path_with_forward_slashes>", "count": <int>}
/// On failure or when no Explorer window is active, returns {"path": "", "count": 0}.
std::string GetExplorerSelection();

/// Close any existing QuickLook standalone windows.
/// @param includePinned  If true, also close pinned windows (whose title is "xmate_ql_pinned").
///                        If false, only close unpinned windows (title "xmate_ql").
/// Returns the number of windows closed.
int CloseQuickLookWindows(bool includePinned = false);
