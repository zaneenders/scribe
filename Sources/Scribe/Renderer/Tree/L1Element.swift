/// ``L1Element`` reduces the number of node types in a tree in order to be
/// flattened further.
indirect enum L1Element {
  case text(String)
  case wrapped(L1Element, key: String, action: BlockAction?)
  case group([L1Element])
}
