/// XMate 事件总线
///
/// 轻量级的发布-订阅模式实现，用于插件间松耦合通信。
library;

class EventBus {
  final Map<String, List<_EventListener>> _listeners = {};

  /// 发布事件
  void emit(String eventName, {Map<String, dynamic>? data}) {
    final listeners = _listeners[eventName];
    if (listeners == null) return;

    for (final entry in listeners) {
      entry.callback(data ?? {});
      if (entry.once) {
        entry.markedForRemoval = true;
      }
    }
    _listeners[eventName]?.removeWhere((e) => e.markedForRemoval);
  }

  /// 监听事件，返回用于取消监听的对象
  EventBusSubscription listen(
    String eventName,
    void Function(Map<String, dynamic> data) handler, {
    bool once = false,
  }) {
    final listener = _EventListener(callback: handler, once: once);
    _listeners.putIfAbsent(eventName, () => []);
    _listeners[eventName]!.add(listener);

    return EventBusSubscription(
        eventName: eventName, listener: listener, bus: this);
  }

  /// 移除事件的所有监听器
  void removeAllListeners(String eventName) {
    _listeners.remove(eventName);
  }

  /// 移除所有监听器
  void clear() {
    _listeners.clear();
  }
}

class _EventListener {
  final void Function(Map<String, dynamic> data) callback;
  final bool once;
  bool markedForRemoval = false;

  _EventListener({required this.callback, this.once = false});
}

/// 事件总线订阅 —— 用于取消监听
class EventBusSubscription {
  final String eventName;
  final _EventListener listener;
  final EventBus bus;

  EventBusSubscription({
    required this.eventName,
    required this.listener,
    required this.bus,
  });

  void cancel() {
    bus._listeners[eventName]?.remove(listener);
  }
}
