part of nyxx;

/// Generic interface for caching entities.
/// Wraps [Map] interface and provides utilities for manipulating cache.
abstract class Cache<S extends SnowflakeEntity> implements Disposable {
  List<S> _cache;

  /// Returns values of cache
  Iterable<S> get values => _cache;

  /// Find one element in cache
  S findOne(bool f(S item)) => values.firstWhere(f, orElse: () => null);
  Iterable<S> find(bool f(S item)) => values.where(f);

  S add(S item) {
    var index = _cache.indexOf(item);
    if(index == -1) {
      _cache.add(item);
      return item;
    }

    _cache.removeAt(index);
    _cache.insert(index, item);
    return item;
  }

  void remove(S item) => _cache.remove(item);

  /// Clear cache
  void invalidate() => _cache.clear();

  /// Loop over elements from cache
  void forEach(void f(S value)) => _cache.forEach(f);

  /// Take [count] elements from cache. Returns Iterable of cache values
  Iterable<S> take(int count) => values.take(count);

  /// Takes [count] last elements from cache. Returns Iterable of cache values
  Iterable<S> takeLast(int count) =>
      values.toList().sublist(values.length - count);

  /// Get first element
  S get first => _cache.first;

  /// Get last element
  S get last => _cache.last;

  /// Get number of elements from cache
  int get count => _cache.length;

  S operator [](Snowflake id) => findOne((d) => d.id == id);

  @override
  Future<void> dispose() => Future(() {
        this._cache.clear();
      });
}

class _SnowflakeCache<T extends SnowflakeEntity> extends Cache<T> {
  _SnowflakeCache() {
    this._cache = List<T>();
  }

  @override
  Future<void> dispose() => Future(() {
        if (T is Disposable) {
          _cache.forEach((v) => (v as Disposable).dispose());
        }

        _cache.clear();
      });
}

/// Cache for Channels
class ChannelCache extends Cache<Channel> {
  ChannelCache._new() {
    this._cache = List<Channel>();
  }

  @override
  Future<Function> dispose() => Future(() {
        _cache.forEach((v) {
          if (v is MessageChannel) v.dispose();
        });

        _cache.clear();
      });
}

/// Cache for messages. Provides few utilities methods to facilitate interaction with messages.
/// []= operator throws - use put() instead.
class MessageCache extends Cache< Message> {
  ClientOptions _options;

  MessageCache._new(this._options) {
    this._cache = List<Message>();
  }

  /// Caches message
  Message _cacheMessage(Message message) {
    if (_options.messageCacheSize > 0) {
      if (this._cache.length >= _options.messageCacheSize) {
        this._cache.removeAt(0);
      }
      this._cache.add(message);
    }

    return message;
  }

  /// Allows to put message into cache
  Message put(Message message) => _cacheMessage(message);

  /// Returns messages which were sent by [user]
  Iterable<Message> fromUser(User user) =>
      values.where((m) => m.author == user);

  /// Returns messages which were sent by [users]
  Iterable<Message> fromUsers(Iterable<User> users) =>
      values.where((m) => users.contains(m.author));

  /// Returns messages which were created before [date]
  Iterable<Message> beforeDate(DateTime date) =>
      values.where((m) => m.createdAt.isBefore(date));

  /// Returns messages which were created before [date]
  Iterable<Message> afterDate(DateTime date) =>
      values.where((m) => m.createdAt.isAfter(date));

  /// Returns messages which were sent by bots
  Iterable<Message> get byBot => values.where((m) => m.author.bot);

  /// Returns messages in chronological order
  List<Message> get inOrder => _cache.toList()
    ..sort((f, s) => f.createdAt.compareTo(s.createdAt));

  @override

  /// Takes first [count] elements from cache. Returns Iterable of cache values
  Iterable<Message> take(int count) =>
      values.toList().sublist(values.length - count);

  @override

  /// Takes last [count] elements from cache. Returns Iterable of cache values
  Iterable<Message> takeLast(int count) => values.take(count);

  /// Get first element
  @override
  Message get first => _cache.last;

  /// Get last element
  @override
  Message get last => _cache.first;
}
