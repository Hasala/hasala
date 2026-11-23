struct Memo<Key: Equatable, Value> {
  private var last: (key: Key, value: Value)?

  mutating func value(for key: Key, _ make: () -> Value) -> Value {
    if let last, last.key == key { return last.value }
    let value = make()
    last = (key, value)
    return value
  }
}
