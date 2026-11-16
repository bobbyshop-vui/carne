import carne/api/addon

newAddon("hello", "0.1.0"):
  exportObject:
    registerFn hello(name: default(string, "world")):
      ## hello([name]) -> greeting string
      return toJS(ctx, "Hello, " & name & "!")
    registerFn add(a: int, b: int):
      ## add(a, b) -> number
      return toJS(ctx, a + b)
