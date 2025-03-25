/// ``Element`` reduces the number of node types in a tree in order to be
/// flattened further.
indirect enum Element {
  case text(String, BlockAction?)
  case wrapped(Element, BlockAction?)
  case group([Element])
  case composed(Element)
}
