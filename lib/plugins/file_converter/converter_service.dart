/// Conversion service — manages a queue of ConversionJobs, runs them
/// sequentially via FFmpeg subprocess.
library;

import 'dart:async';
import 'models/conversion_job.dart';
import 'models/output_type.dart';
import 'converter_engine.dart';

class ConverterService {
  final String ffmpegPath;
  final String qpdfPath;
  final List<ConversionJob> _jobs = [];
  ConversionJob? _currentJob;
  ConverterEngine? _currentEngine;

  /// Max parallel conversions.
  final int maxParallel;

  /// Hardware acceleration mode.
  final HardwareAcceleration hwAccel;

  final _jobCtrl = StreamController<List<ConversionJob>>.broadcast();
  final _jobAddedCtrl = StreamController<ConversionJob>.broadcast();
  final _jobUpdatedCtrl = StreamController<ConversionJob>.broadcast();

  /// Full job list stream (for UI list rebuilds).
  Stream<List<ConversionJob>> get jobListStream => _jobCtrl.stream;

  /// Individual job added.
  Stream<ConversionJob> get onJobAdded => _jobAddedCtrl.stream;

  /// Individual job progress updates.
  Stream<ConversionJob> get onJobUpdated => _jobUpdatedCtrl.stream;

  /// All jobs in the queue (including completed).
  List<ConversionJob> get jobs => List.unmodifiable(_jobs);

  /// Currently active job.
  ConversionJob? get currentJob => _currentJob;

  /// Number of active (in-progress) jobs.
  int get activeCount =>
      _jobs.where((j) => j.state == ConversionState.inProgress).length;

  /// Number of queued (ready) jobs.
  int get queuedCount =>
      _jobs.where((j) => j.state == ConversionState.ready).length;

  ConverterService({
    required this.ffmpegPath,
    this.qpdfPath = '',
    this.maxParallel = 1,
    this.hwAccel = HardwareAcceleration.off,
  });

  /// Add a job to the queue and start processing if idle.
  void enqueue(ConversionJob job) {
    job.prepare();
    _jobs.add(job);
    _jobAddedCtrl.add(job);
    _emitJobList();
    _processQueue();
  }

  /// Add multiple jobs at once.
  void enqueueAll(List<ConversionJob> jobs) {
    for (final j in jobs) {
      j.prepare();
      _jobs.add(j);
      _jobAddedCtrl.add(j);
    }
    _emitJobList();
    _processQueue();
  }

  /// Cancel a specific job.
  void cancelJob(ConversionJob job) {
    if (job.state == ConversionState.ready) {
      job.markFailed('Cancelled');
      _jobUpdatedCtrl.add(job);
      _emitJobList();
    } else if (job == _currentJob && job.isInProgress) {
      _currentEngine?.cancel();
    }
  }

  /// Cancel all jobs.
  void cancelAll() {
    for (final j in _jobs) {
      if (j.state == ConversionState.ready) {
        j.markFailed('Cancelled');
      }
    }
    _currentEngine?.cancel();
    _emitJobList();
  }

  /// Clear completed/failed jobs from the list.
  void clearCompleted() {
    _jobs.removeWhere(
        (j) => j.state == ConversionState.done || j.state == ConversionState.failed);
    _emitJobList();
  }

  void dispose() {
    _currentEngine?.dispose();
    _jobCtrl.close();
    _jobAddedCtrl.close();
    _jobUpdatedCtrl.close();
  }

  // ── Internal ──

  Future<void> _processQueue() async {
    if (activeCount >= maxParallel) return;

    // Find next ready job
    for (final job in _jobs) {
      if (job.state != ConversionState.ready) continue;
      if (job.isInProgress) continue;

      _currentJob = job;
      final engine = ConverterEngine(
        job: job,
        ffmpegPath: ffmpegPath,
        qpdfPath: qpdfPath,
        hwAccel: hwAccel,
      );
      _currentEngine = engine;

      // Listen for progress
      engine.progressStream.listen((j) {
        _jobUpdatedCtrl.add(j);
        _emitJobList();
      });

      // Run & wait
      await engine.run();

      _currentEngine = null;
      _currentJob = null;

      _jobUpdatedCtrl.add(job);
      _emitJobList();

      // Process next job (sequential)
      _processQueue();
      break;
    }
  }

  void _emitJobList() {
    if (!_jobCtrl.isClosed) {
      _jobCtrl.add(List.from(_jobs));
    }
  }
}
