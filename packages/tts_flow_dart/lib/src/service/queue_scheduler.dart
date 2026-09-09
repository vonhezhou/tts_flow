import 'dart:collection';

final class QueueScheduler<T> {
  final Queue<T> _queue = Queue<T>();

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;

  void enqueue(T item) {
    _queue.addLast(item);
  }

  T dequeue() {
    return _queue.removeFirst();
  }

  List<T> drain() {
    final items = _queue.toList(growable: false);
    _queue.clear();
    return items;
  }

  /// Removes and returns the first item satisfying [test], if any.
  T? removeFirstWhere(bool Function(T item) test) {
    for (final item in _queue.toList(growable: false)) {
      if (test(item)) {
        _queue.remove(item);
        return item;
      }
    }
    return null;
  }
}
