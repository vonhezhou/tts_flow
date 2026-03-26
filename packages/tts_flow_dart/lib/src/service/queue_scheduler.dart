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
}
