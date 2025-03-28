enum L2Element {
  case text(String, L2Binding?)
  case group([L2Element])
}

struct L2Binding {
  let key: String
  let action: BlockAction
}
