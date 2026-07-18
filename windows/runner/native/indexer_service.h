// XMate Indexer Service — Windows Service entry point.
#pragma once

/// Entry point for --run-service mode.
/// Registers with SCM and enters the service main loop.
/// Returns EXIT_SUCCESS on clean stop, EXIT_FAILURE on error.
int IndexerServiceMain();
